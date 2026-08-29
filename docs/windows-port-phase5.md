# Phase 5 — CI and release

Status: Windows is now built, packaged, released, and smoke-tested by CI. The
unit suite is **not** run on Windows, because it does not yet compile there.
That gap is the phase's main finding, and it is measured rather than asserted:
eight declarations, listed below, block it.

## Finding 10 — the product compiled for Windows; the test binary never did

Phases 0–4 verified Windows with `zig build -Dtarget=x86_64-windows`. That
builds the product. It had never been paired with the test build, and the two
analyze different amounts of code.

Zig analyzes container-level declarations lazily. A POSIX-only function that no
Windows code path reaches is never type-checked in a product build, even when
it sits in a file the Windows build imports. A `test` block is different: the
test binary references every test in the module, so every POSIX assumption a
test makes is forced through semantic analysis for the target being built.

Measured on `1fa8fc3`, both against `x86_64-windows`:

| build | result |
| --- | --- |
| `zig build` | **succeeds** |
| `zig build test` | **fails — 72 errors across 27 files** |

So "Windows compiles" was true and remains true, but it was a narrower claim
than it sounded. Nothing regressed; a second, larger surface had simply never
been looked at.

### What the 72 errors were

Almost all of them were tests asserting POSIX semantics that have no Windows
meaning — `stat.permissions.toMode() & 0o777` against a `Permissions` that is a
`DWORD` enum on Windows, `AT.FDCWD`, `SIG.TTIN`, `std.c.fork`.

55 of them are now guarded with the standard skip idiom, placed as the first
statement of the test body:

```zig
if (builtin.os.tag == .windows) return error.SkipZigTest;
```

This is load-bearing beyond skipping at runtime: because `builtin.os.tag` is
comptime-known, the branch is taken unconditionally and everything after it in
the body becomes unreachable, so Sema stops. The guard is what makes the
*compile* succeed, not just the run. That was verified directly before relying
on it — a probe file whose body is a hard type error on Windows compiles clean
for `x86_64-windows` behind the guard.

The guards cost POSIX nothing: on Linux and macOS the condition is comptime
false and each test runs exactly as before.

### The eight that remain

72 → 8. The residual is not more of the same, which is why it stops here:

| site | POSIX dependency | kind |
| --- | --- | --- |
| `command_runner.zig:79` | `std.posix.SIG.USR1` | product |
| `manager.zig:11285` | `std.c.fork` | product |
| `tool_host.zig:2594` | `std.c.fork` | product |
| `native_session.zig:4307` | `std.c.kill(-pid, …)` | product |
| `native_session.zig:6313` | `std.c.SIG.HUP` | product |
| `tmux_session.zig:1694` | `AF.UNIX` socket | product |
| `background_runtime.zig:2612` | `std.c.waitpid` | test helper |
| `store.zig:7261` | `std.c.getpid` | test helper |

Six are product declarations belonging to subsystems this port has not reached:
foreground-session signalling, fork-based subagents, the native terminal session
backend, and tmux sessions. Each could be made to compile today by adding a
comptime terminator — `if (builtin.os.tag == .windows) unreachable;` — but that
would assert something not yet true, that Windows never reaches the function.
The claim is unverifiable from here, and if any instance of it were wrong the
result would be a runtime crash on Windows where there is currently a compile
error. Trading a compile-time guarantee for an unchecked runtime one, in
subsystems nobody has ported, is a bad trade in a phase about CI.

So the eight stay, and they are useful where they are: they are a
compiler-maintained inventory of what porting those subsystems must cover, and
they will fail loudly the moment someone claims a subsystem is done.

**Entry criterion for a Windows unit-test job: this list is empty.**

One case is worth singling out. `io.zig` has a table test that calls
`process_io_for(.macos, …)` from any host, to check the Darwin `std.Io` wrapper
without being on Darwin. That pattern does not survive a Windows build: passing
`.macos` selects the Darwin branch, but `std.posix.fd_t` still follows the
*build target*, so the module's `fd_t = 64` is checked against Windows' `HANDLE`
and fails. Five of the original 72 errors came from that one call. A tag-passing
table test is only host-independent as far as the types it touches are.

## What CI now does

**`ci.yml` — `cross-target`, every pull request.** `x86_64-windows` joins the
existing four targets. This is the regression guard the port did not have:
everything phases 0–4 built was verified by a build run by hand, once, and
nothing would have caught a later change breaking it. Each matrix entry gained
an explicit `bin` (`fx` / `fx.exe`) because the size-report step stats the
binary by name.

**`full-ci.yml` — `native-windows`, a real Windows runner.** Builds and
smoke-tests `fx.exe help` and `fx.exe status --json`, asserting non-empty stdout
and empty stderr, matching the POSIX native jobs.

This is the first time any of this code runs on Windows. Phases 2–4 verified
runtime behavior under wine, which is a partial surface: it does not implement
`NtLockFile`, any AFD socket IOCTL, or ConPTY data flow. A smoke test on a real
runner covers what unit tests would not have covered anyway — process startup,
console initialization, and stray stderr.

It is a separate job rather than a fifth entry in the `native` matrix because
the shared steps diverge: `check-public-surface.sh` is a repo-content check that
gains nothing from a fifth platform and would need Git Bash to run, and the
unit-test step cannot be there at all. It is also deliberately **not** added to
the `full-suite` aggregator, which requires each platform to have a native job
*and* four E2E shards.

**The E2E suite remains POSIX-only.** It is Bun + tmux with
`FX_REQUIRE_TMUX: "1"`, and the shard runner resets a tmux server between files.
A Windows E2E harness is its own project.

## What release now does

The plan predicted the packaging trap correctly. The package step hard-coded
`cp zig-out/bin/fx` and `tar -czf`; a Windows target emits `fx.exe`, so adding a
matrix entry alone would have failed at packaging and uploaded nothing.

`build-windows` cross-compiles on `ubuntu-latest` — the same trick the Linux
matrix uses, and cheaper than a Windows runner for a build with nothing to sign.
It packages `fx-windows-x86_64.zip` with `fx.exe`, `LICENSE`, and
`THIRD_PARTY_NOTICES.md` flat at the archive root, matching the tar.gz layout,
plus a `.sha256` beside it.

Both the GitHub release `files:` globs and the CDN upload loop were extended;
the CDN's content-type selection became a `case`, because the previous
rule-ordering approach would have typed `fx-windows-x86_64.zip.sha256` as
`application/zip`. The four filename shapes were checked directly, and the two
pre-existing ones resolve exactly as before.

The packaging step was run locally against a real cross-compiled `fx.exe`: the
archive contains the three expected entries at the root and the checksum
verifies.

### Two things the release does not do

**The archive is unsigned.** macOS artifacts are signed and notarized;
Authenticode signing needs a certificate this repository does not hold, so
SmartScreen will warn on first run. This is a distribution decision, not a
packaging one.

**Nothing in this repository installs the artifact.** The CDN layout gained
`.zip` and `.zip.sha256`, but the installer that consumes `latest.txt` lives
outside this tree and still expects a `.tar.gz`. Publishing a Windows archive
does not by itself make `fx` installable on Windows; whoever owns the installer
has to handle the new shape.

## Still open after phase 5

Phase 5 changes what is *observed*, not what works. Everything the earlier
phases could not verify is still unverified, and now has somewhere to be
verified from:

- ConPTY data flow and `ResizePseudoConsole` — wine creates a pseudoconsole but
  does not wire I/O to it.
- Anything socket-shaped, including the model gateway. Zig implements Windows
  sockets over AFD, and wine implements none of those IOCTLs. `fx status --json`
  is the smoke test precisely because it needs no network.
- Every advisory-lock write path — wine's `NtLockFile` returns
  `STATUS_NOT_IMPLEMENTED`.
- `verifies_confidentiality` is still false; the DACL check is still owed.
- The eight declarations above, and the unit suite they block.
