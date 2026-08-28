# Windows port — phase 0 compile spike results

Companion to [`windows-port.md`](windows-port.md), which called this spike its
first blocking action. This records what the compiler actually says.

## What was run

```
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
```

Zig 0.16.0, matching `.minimum_zig_version` in `build.zig.zon`. The plan noted
`ziglang.org` is blocked by the sandbox network policy; the toolchain came from
the `ziglang` PyPI package instead, which the Zig Software Foundation
publishes and which resolves through an allowed host. `.dependencies = .{}`,
so the build needed no network fetch.

**Result: 30 compilation errors** — 25 in `src/`, 5 inside Zig's standard
library triggered by our usage. Zero object files produced.

## The headline result reframes the port's size

Nothing appeared from `native_session.zig`, `tmux_session.zig`,
`process_tree.zig`, `direct_command.zig`, `command_runner.zig`, or
`shell_resolver.zig` — the files carrying the heaviest POSIX surface in the
tree.

This is finding 1 of the plan confirmed from the other direction. The comptime
gate that makes flipping `terminalSupportForOs` dangerous is the same gate
keeping the Windows build at 30 errors instead of thousands: `Registry =
UnsupportedRegistry` prunes the terminal backend, and Zig's lazy analysis
prunes everything only it references. **The port starts from a far better
position than the raw POSIX line count suggests, and it stays there exactly as
long as the flags stay off.**

## Error clusters, with owners

| # | Cluster | Errors | Owner |
| --- | --- | --- | --- |
| A | `Io.File.Permissions` has no `fromMode`/`toMode` on Windows | 15 | Private-state security model (phase 1) |
| B | `std.posix.fd_t` is `*anyopaque` (a HANDLE), not an integer | 11 | Platform IO seam (phase 1) |
| C | Process args and environment ABI | 2 | Platform IO seam (phase 1) |
| D | Explicit `@compileError` in our own code | 1 | Path handling (phase 1) |
| E | Comptime access to the Windows PEB | 1 | Platform IO seam (phase 1) |

Clusters B and E each account for some of the five standard-library errors;
those are fallout from our call sites, not std bugs.

### Cluster A — POSIX mode bits (15 errors, 11 files)

On Windows `std.Io.File.Permissions` is `enum(DWORD)`, so `fromMode(0o600)` and
`stat.permissions.toMode()` do not exist.

```
src/core/shared/io.zig:491, :511, :512, :848
src/core/session/session_log.zig:21, :1431
src/core/session/session_authority.zig:646
src/core/session/session_child_store.zig:6
src/core/session/session_store.zig:486
src/core/session/session_summary_codec.zig:209
src/core/auth/oauth_session.zig:773
src/core/auth/chatgpt_session.zig:116
src/core/auth/grok_session.zig:124
src/core/hosts/native_secret_store.zig:133
src/acp/prompt_test_controls.zig:4
```

This confirms finding 3 of the plan and **enlarges it in one direction while
softening it in another**. The plan located the problem in `io.zig`'s
`VerifiedDir`; in fact eleven files across `session/`, `auth/`, `hosts/`, and
`acp/` reach for mode bits directly. But it is also the cheapest cluster to
close: a single `Permissions` shim — `fromMode`/`toMode` equivalents that
compile to mode bits on POSIX and to an ACL check on Windows — retires **15 of
the 25 source errors, 60% of the total, from one small abstraction.** That is
the highest-leverage single change in the whole port and should be done first
within phase 1.

### Cluster B — `fd_t` is a HANDLE (11 errors)

`std.posix.fd_t` is `*anyopaque` on Windows. Three distinct symptoms:

*File descriptor constants* — `STDIN_FILENO`/`STDOUT_FILENO` are `comptime_int`
and no longer assignable:

```
src/acp/jsonrpc.zig:312
src/core/cli/cli_surface.zig:1857, :1909
src/ui/ask_presentation.zig:35
src/ui/shell_runtime.zig:67
```

`cli_surface.zig` is finding 2 of the plan confirmed: those two lines are the
masked API-key entry path, and they break the build.

*Process IDs used as arithmetic* — `background_process.zig:508` negates a pid
(`sendSignal(-root_pid, …)`, the process-group kill), and formats pids with
`{d}` at `:88`, `:1036`, `:1205`, `:1264`. The latter are what produce the
`std/Io/Writer.zig:1803` and two `std/fmt.zig:436` errors: you cannot format a
pointer as a decimal integer.

*Socket descriptors* — `http_fetch.zig:1297` casts a raw result to `fd_t`, and
its `pollfd` use produces `std/c.zig:4299` (`ws2_32` has no `pollfd`).

### Cluster C — args and environment ABI (2 errors)

```
src/main.zig:3154  expected '[]const u16', found '[]const [*:0]const u8'
src/main.zig:3160  no field named 'slice' in 'process.Environ.GlobalBlock'
```

Windows passes UTF-16 argv and structures its environment block differently.
The plan flagged `getenvFromBlock` returning `null` on Windows as a phase 1
item; the reality is stronger — the argument vector itself does not type-check,
so this is startup-blocking, not a degraded-lookup issue.

### Cluster D — our own unimplemented marker (1 error)

`src/core/shared/io.zig:972` — `@compileError("dirRealpathAlloc not implemented
for this OS")`. A deliberate marker; needs `GetFinalPathNameByHandleW`.

### Cluster E — comptime PEB access (1 error)

`src/ui/transcript/runtime.zig:4095` uses `std.Io.File.stdout()` as a struct
field default. On Windows that reads the PEB through inline asm, which cannot
run at comptime. The field has to become lazy or optional.

## Corrections to the merged plan

The spike contradicts the plan in one place and shows two gaps.

**Wrong: `hosts/native.zig` is not a compile blocker.** The plan listed its
`std.c.waitpid` / `std.c.W.*` / `std.posix.kill` use as ungated. It produced
zero errors. Those helpers are reachable only from `copy_file_to_clipboard`,
which opens with `if (comptime builtin.os.tag != .macos) return false;`, so
Zig prunes the entire chain. The gate exists one level above where the audit
looked.

**Missed: `src/ui/shell_runtime.zig`.** Genuinely ungated POSIX — `termios`,
`posix_openpt`, `poll` — and it errors at `:67`. The plan never mentioned it.

**Missed: `src/tools/web/http_fetch.zig`.** 3,883 lines with 127 POSIX/libc
call sites: raw BSD sockets (`sockaddr`, `AF`, `SOCK`, `socketpair`,
`getsockopt`), `poll`, `pipe`, `sigaction`.

That last one looks alarming and is not, which is worth stating precisely
because the instinct is to panic about the network layer. **The model gateway
does not use it.** `src/gateway/client.zig` is built on `std.http.Client`,
which is portable, and carries only seven POSIX references (`setsockopt` for
`SO_LINGER` and `SO_RCVBUF`). `http_fetch.zig` has exactly one importer,
`src/tools/web/fetch.zig` — the WebFetch tool.

**Scope consequence:** add the WebFetch tool to v1's deferred list, alongside
clipboard and background processes. Talking to a model on Windows does not
depend on any of that code.

**Unconfirmed but expected:** `login_flow.zig`'s `TeamPickerRawMode` did not
error, though it is ungated and structurally identical to the `cli_surface.zig`
code that did. Lazy analysis almost certainly stopped before reaching it.

## This inventory is a lower bound

Zig stops analyzing a declaration once it fails, so errors hide behind errors.
30 is the count on the *first* pass. Expect the number to move as clusters are
retired — the honest reading is "30 errors across 5 clusters, no cluster
requiring a new subsystem", not "30 errors and then done".

Phase 0 is complete in the sense that matters: every failure is triaged, every
cluster has an owner, and none of them is a surprise architecture problem. The
inventory should be regenerated after cluster A lands, since that pass will
reach code the compiler has not yet analyzed.

## Recommended order within phase 1

1. **`Permissions` shim** — retires 15 of 25 source errors from one seam.
2. **`fd_t` seam** — a platform-neutral handle type plus stdio accessors,
   covering cluster B's five constant sites.
3. **`main.zig` args/env** — startup-blocking, small, self-contained.
4. **`dirRealpathAlloc`** and the **`File.stdout()` field default** — two
   isolated fixes.
5. **Gate `ui/shell_runtime.zig`** rather than porting it; the interactive
   shell is phase 4 work.

Cluster B's pid arithmetic in `background_process.zig` should be *gated*, not
ported, in phase 1 — background processes are deferred from v1, and the Job
Object work in phase 2 replaces that code wholesale.
