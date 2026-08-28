# Windows port — phase 1 results

Companion to [`windows-port.md`](windows-port.md) and
[`windows-port-phase0.md`](windows-port-phase0.md).

Phase 1's exit condition was that the tree compiles for Windows and that macOS
and Linux behavior is unchanged. Both are met.

## The binary exists

```
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
→ zig-out/bin/fx.exe: PE32+ executable (console) x86-64, for MS Windows
```

Zero compile errors, zero link errors. Capability flags in
`src/core/hosts/host.zig` are unchanged, as the plan requires: the flags flip
at the end of the phase that earns them, and nothing here earns one.

## Two seams

**`src/core/shared/file_permissions.zig`** replaces direct POSIX mode-bit
arithmetic. Predicates state intent — `isPrivateToOwner`,
`isExactlyPrivateFile`, `isExactlyPrivateDir`, `isOwnerWritable`,
`isWritable`, `isProtectedFromGroupAndOther`, `toRawBits` — and every POSIX
branch is the exact bit test it replaced.

The module exports `verifies_confidentiality`, which is **false on Windows**.
The confidentiality predicates there permit rather than verify, because
`Permissions` on Windows carries no owner/group/other classes. Private state
currently rests on the ACL inherited from the user profile directory, which
this module does not read. A test asserts the constant per platform, so the
gap is greppable and cannot be silently assumed away. **Replacing those
branches with a real DACL check (owner and SYSTEM only) remains the open
Windows security item.**

**`src/core/shared/stdio.zig`** supplies comptime-safe standard stream
handles. Windows keeps them in the process environment block, readable only at
runtime, and `std.posix.fd_t` there is `*anyopaque` rather than an integer, so
neither the descriptor constants nor `std.Io.File.stdout()` can serve as a
struct-field default.

## Phase 0's inventory was a large undercount

Phase 0 reported 15 errors in cluster A and warned the number was a lower
bound. The real count is roughly **180 mode-bit call sites across the tree** —
about twelve times what the compiler had reached. Zig stops analyzing a
declaration once it fails, so the first pass saw only the shallowest layer.

The practical consequence is a method, not a number: retire a cluster, rebuild,
read the next wave. The error count moved 30 → 28 → 26 → 22 → 15 → 8 → 3 → 1 →
0, and the *composition* changed at every step. Bulk-editing against the first
inventory would have missed most of the work and touched code that is pruned
on Windows anyway.

## An upstream Zig bug worth knowing

`std.Io.File.Permissions.readOnly`, `setReadOnly`, and `toAttributes` **cannot
be called from portable code** in Zig 0.16.0. They reference
`windows.FILE_ATTRIBUTE_READONLY`, which no longer exists, and `toAttributes`
bit-casts the permission enum into `windows.FILE.ATTRIBUTE` — the
`PS_ATTRIBUTE` *process*-attribute struct, unrelated to file attributes.

This invalidated the natural design. `readOnly()` appears on both platforms
and looks like the portable spelling of `mode & 0o222 == 0`; it is not. On
Windows only the enum tags and `@intFromEnum` are sound.

## Two path-resolution traps found in review

Both were in the new Windows `realpath` helpers, both affect containment
checks, and neither fails loudly.

`dirRealpathAlloc` returned `join(dir_path, sub_path)` unresolved on Windows
while the POSIX branches pass the join through `realpathAlloc`. That skips
canonicalization of `..`, symlinks, and junctions, and makes
`dirRealpathAlloc(dir, "missing")` succeed with a fabricated path — so a
caller using it to prove existence or obtain a canonical identity could
authorize the wrong one. The branch is now structurally identical to the
POSIX ones: acquire, join, resolve.

`GetFinalPathNameByHandleW` returns a UNC handle as
`\\?\UNC\server\share\...`. Stripping only the `\\?\` prefix leaves
`UNC\server\share\...` — a **relative** path. A home or workspace on a
network share would canonicalize to somewhere else entirely, silently. The UNC
form is now rewritten to `\\server\share\...`, and that test has to precede
the general prefix strip because `\\?\UNC\` starts with `\\?\`.

The general lesson for later phases: a Windows path helper that looks right for
`C:\...` can still be wrong for the UNC and long-path forms of the same API,
and the wrongness is a silently incorrect location rather than an error.

## Masked API-key entry declines on Windows

Hiding a pasted key as it is typed needs `SetConsoleMode`, which is not in
std and would be untested Win32 code handling a secret. The failure mode of
getting it wrong — echo not actually disabled — prints the user's API key on
screen.

`setupTerminalAvailableDefault` therefore returns false on Windows, and
`fx setup` reports that an interactive terminal is required. The fallback
path was checked: it declines, and **never echoes the key**. Console raw mode
belongs with the auth work in phase 3, where it is the focus and can be
tested.

## What is gated, and where it returns

Every deferred path is gated at the point that *forces analysis*, not merely
declared out of scope — the phase 0 correction applied throughout.

| Gate | Site | Returns in |
| --- | --- | --- |
| Background processes | the `Provider` const in `background_process.zig` | phase 2 (Job Objects) |
| WebFetch transport | the `http_fetch` reference in `fetch.zig` | after v1 |
| Process-group signalling | `terminateRemainingProcessGroup` | phase 2 |
| herdr client | its socket send path | after v1 |
| OAuth browser callback | the `poll` loops in `browser_callback.zig` | phase 3 |
| Masked key entry, team picker | `cli_surface.zig`, `login_flow.zig` | phase 3 |
| termios, `TIOCGWINSZ`, event-loop poll | the TUI paths | phase 4 |
| Auto-upgrade artifact | `supports_published_artifact` | phase 5 |

The gates that report a status use the value the caller already understands
rather than a new error, because introducing one narrows an inferred error set
on Windows and turns a `switch` prong elsewhere into an unreachable `else`.
That failure mode appeared three times.

## Verification

POSIX behavior is unchanged, measured rather than assumed. The same suite was
run on this branch and on the pre-phase-1 commit `ef6eb04`:

| | total | pass | skip | fail |
| --- | --- | --- | --- | --- |
| `ef6eb04` (before) | 8595 | 8545 | 21 | 29 |
| phase 1 | 8606 | 8556 | 21 | 29 |

The failing sets are identical: **no test fails on this branch that did not
already fail on the base.**

> Later note: re-measured against `main` during phase 2, the pre-existing
> failure count is 30 rather than 29. The container drifted between the two
> runs; see the phase 2 results for the detail. The comparison above is still
> valid, because both rows were measured together — which is the point.

The 29 failures are pre-existing in this
container — `command_runner` cases exercising `setsid`, double-forked
descendants, and signal-driven teardown, which need a fuller process
environment than a sandbox provides. The `+11` in total and pass is exactly
the new tests in the two seam modules.

Also green: `zig fmt --check src/`, `./scripts/check-public-surface.sh`, the
native ReleaseSafe build, and the smoke test the native CI jobs run
(`fx help` and `fx status --json`, non-empty stdout with empty stderr).

## Not verified

`fx.exe` has never been executed. There is no Windows machine in this
environment, so everything above is a build-and-link result plus a POSIX
regression proof. Whether the binary starts, reads its config, and prints help
on a real Windows host is the first thing phase 5's `windows-latest` job will
answer — and until it does, the phase 1 exit criterion is met only in the
sense the compiler can attest to.
