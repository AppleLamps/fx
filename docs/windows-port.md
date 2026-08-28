# Windows platform port — scope, sequencing, and phase plan

Status: proposal. No implementation in this document.

> **Phase 1 is complete.** `fx.exe` builds and links for `x86_64-windows`
> with POSIX behavior measured unchanged. See
> [`windows-port-phase1.md`](windows-port-phase1.md) — including the open
> Windows security item (`verifies_confidentiality` is false) and the note
> that the binary has not yet been run on a real Windows host.
>
> **Phase 0 has since been run.** See
> [`windows-port-phase0.md`](windows-port-phase0.md) for the real compiler
> output: 30 errors across 5 clusters. It confirms findings 1, 2, and 3,
> corrects one claim below (marked inline), and adds two files this audit
> missed. Where the two documents disagree, the compiler wins.

`fx` targets macOS and Linux today. This document scopes a real Windows port:
what ships in v1, what is deliberately deferred, and the order the work has to
happen in. It is grounded in an audit of the current tree rather than on
assumptions about it.

## Summary

Windows is not merely *gated off* at the host layer. Parts of the tree do not
compile for `x86_64-windows` at all, and the blockers are not where a
capability-flag-first plan would look for them:

1. `terminalSupportForOs` is a **compile gate**, not a declaration. Flipping it
   is the *last* step of the port, not the first.
2. The un-gated POSIX code sitting in the v1 CLI path is in **auth's terminal
   input**, which a "auth is phase 3" plan would schedule far too late.
3. **Credential storage is already portable.** The macOS Keychain is not a
   blocker. The private-state permission model underneath it is.
4. The interactive terminal is **tmux-shaped**, not merely POSIX-shaped, and is
   correctly deferred.

Each is expanded below with the evidence.

---

## Finding 1 — the capability flag is a comptime compile gate

`src/core/hosts/host.zig` looks like a declarative capability table, but
`terminal` is load-bearing for *what gets compiled*:

```zig
// src/core/terminal/native_session.zig:653
pub const Registry = if (isSupported()) SupportedRegistry else UnsupportedRegistry;
```

`isSupported()` resolves through `host_capabilities.terminalSupportForOs`
(`src/core/terminal/native_session.zig:266`, and the same pattern in
`src/core/terminal/host.zig`). Both files carry a test asserting that backend
selection *follows* the host capability value, so the coupling is intentional
and enforced.

**Consequence.** Setting `terminal = .supported` for Windows as the opening
move pulls ~37k lines of POSIX terminal backend — `native_session.zig`
(270 KB, 107 POSIX/libc call sites) and its `tmux_session.zig` dependency
(92 KB) — into the Windows build and breaks it immediately.

**Rule for this port:** build the Windows backend behind the existing flag,
then flip the flag as the closing step of that phase. Every phase below ends
with a flag flip, never begins with one.

## Finding 2 — the compile breaks are in auth's terminal input

Most platform-sensitive code in the tree is already `comptime`-gated. Three
places in the v1 path are not:

| Location | Problem |
| --- | --- |
| `src/core/cli/cli_surface.zig:1904` | `MaskedKeyRawMode` — `std.posix.termios`, `tcgetattr`, `tcsetattr`, `std.c.isatty`, no gate. This is masked API-key entry. |
| `src/core/auth/login_flow.zig:1275` | `TeamPickerRawMode` — same construct, same lack of gate. |
| ~~`src/core/hosts/native.zig`~~ | ~~Clipboard reaping uses `std.c.waitpid`, `std.c.W.*`, `std.posix.kill` ungated.~~ **Wrong — corrected by phase 0.** These helpers are reachable only from `copy_file_to_clipboard`, which opens with a comptime macOS gate, so Zig prunes the chain. This file produces zero Windows errors. |
| `src/ui/shell_runtime.zig` | *Added by phase 0.* Genuinely ungated `termios`, `posix_openpt`, and `poll`; errors at `:67`. Gate it — the interactive shell is phase 4 work. |

`MaskedKeyRawMode` is reached from `cli_surface.zig:1867` on the API-key setup
path — a v1 requirement. So the raw-mode input half of auth belongs in
**Phase 1**, not a late auth phase. Only the *token storage* half is deferrable.

The fix is a small platform seam: a `RawMode` abstraction with a POSIX
implementation and a Windows implementation over
`SetConsoleMode`/`ENABLE_ECHO_INPUT`, plus a non-TTY fallback.

## Finding 3 — credential storage is already portable

`selectStorageBackend` already returns `.profile_file` for every non-macOS
target, and there is a passing test asserting exactly that for Windows:

```zig
// src/core/auth/oauth_session.zig:82
fn selectStorageBackend(os_tag: std.Target.Os.Tag, keychain_disabled: bool) StorageBackend {
    if (os_tag == .macos and !keychain_disabled) return .macos_keychain;
    return .profile_file;
}

// src/core/auth/oauth_session.zig:990
try std.testing.expectEqual(StorageBackend.profile_file, selectStorageBackend(.windows, false));
```

`src/core/hosts/native_secret_store.zig` mirrors this. Linux ships on the
profile-file backend today.

**The real blocker is one level down.** Every credential, session, and
subagent-approval write goes through `VerifiedDir` in
`src/core/shared/io.zig`, which enforces confidentiality with POSIX mode bits:

- `verifyPrivateDirectory` requires mode `0o700` (`io.zig:579`)
- `verifyPrivateRegularFile` requires mode `0o600` (`io.zig:573`)
- `openOrCreateVerifiedPrivateChild` calls `setPermissions` then verifies, and
  returns `error.PrivateStatePermissionsUnsupported` on failure (`io.zig:629`)
- `syncVerifiedDir` returns `error.OperationUnsupported` on Windows outright
  (`io.zig:588`)

Windows has no equivalent mode bits, so this fails for reasons that have
nothing to do with the Keychain. `PrivateStatePermissionsUnsupported` is
already threaded through `terminal/store.zig`, `terminal/host.zig`,
`subagent/approval_persistence.zig`, `subagent/authority.zig`, and
`subagent/control_store.zig` — the blast radius is wide.

**Re-scope this work item** from "replace macOS-only credential storage" to
"define the Windows private-state security model": an ACL-based check (owner-
and-SYSTEM-only DACL) that satisfies the same contract as the mode-bit check,
plus a `FlushFileBuffers`-backed directory sync. A native Credential Manager or
DPAPI backend is a later enhancement, not a v1 requirement.

## Finding 4 — the interactive terminal is a second backend, not a rework

`native_session.zig` drives its sessions through `tmux_session.zig`
(`native_session.zig:8`, and backend start/recover at `:3505`/`:3588`), with
PTYs allocated via `posix_openpt` (`native_session.zig:5830`,
`src/ui/shell_runtime.zig:571`). Windows has no tmux.

This is not "rework terminal handling for console resizing" — it is a second
backend implemented against `src/core/terminal/contracts.zig` on ConPTY
(`CreatePseudoConsole` / `ResizePseudoConsole`), with session persistence and
recovery rebuilt on something other than a tmux server. Deferring it is the
right call, and it should be scoped as its own project.

---

## Two seams already exist — copy them

The tree already demonstrates the "shared interface, per-OS implementation"
pattern twice. New platform seams should match these rather than invent a
third shape:

**Table-driven `os_tag` switch with an injectable launcher** —
`src/core/hosts/url_opener.zig`. Adding Windows is roughly three lines
(`cmd /c start` or `rundll32 url.dll,FileProtocolHandler`) plus a test
alongside the existing macOS/Linux ones.

**Vtable with an explicit unsupported default** —
`src/core/execution/background_process_provider.zig`, whose
`unsupportedSpawnPrepared` returns `error.Unsupported`. This is the right shape
for process spawn, tree termination, and signalling.

`src/core/workspace/workspace_files.zig:262` (Windows git paths) and
`src/core/app/app_commands.zig:2013` (`.windows => .default_file`) show the
same instinct applied at leaf level.

---

## Scope for v1

**In scope.** Startup and `--version`/help; the non-interactive CLI surface;
config and session persistence; workspace file access, search, and git
discovery; shell execution through the approval path; the permission system;
API-key and OAuth login.

**Out of scope, explicitly.** The WebFetch tool — phase 0 found
`src/tools/web/http_fetch.zig` carries 3,883 lines of raw BSD sockets and
`poll`, but its only importer is `src/tools/web/fetch.zig`, and the model
gateway runs on portable `std.http.Client`, so deferring it costs nothing that
v1 needs. Note that deferring it is not self-executing: `builtins/tools.zig:32`
imports it unconditionally and `:783-787` takes function pointers into it, so
it needs a real comptime gate to stop being compiled. Also: the interactive TUI and terminal sessions;
background/detached processes; the direct read-only fast path; native
clipboard; tmux-based session recovery; the E2E suite on Windows; a native
credential-manager backend.

**Degraded but acceptable in v1.** Windows takes the approval path for every
command. `command_effect.plan` already returns
`.approval_required = .unsupported_platform` for non-macOS/Linux targets
(`src/core/shell_command/command_effect.zig:313`) and
`src/core/permissions/direct_command.zig:198`
returns `error.UnsupportedDirectPlatform` to match. That is safe and correct,
just slower — **porting the direct read-only pipeline is not required to ship
a working Windows product.** This is a significant scope cut worth taking.

---

## Phases

Each phase ends by flipping the capability flag it earned, never begins with it.

### Phase 0 — compile spike (blocking, do first)

Run `zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows` and capture the
full error inventory. Nothing below can be sized honestly without it. Triage
each error into: needs a comptime gate, needs a real Windows implementation, or
needs a design decision.

Exit: a triaged error list with an owner per cluster.

### Phase 1 — it compiles, starts, and reads its config

Gate or port the un-gated POSIX in the CLI path (Finding 2). Implement the
Windows private-state model in `io.zig` (Finding 3). Add the Windows arm to
`url_opener.zig`. Audit path handling for separators, drive letters, and
case-insensitivity; `%USERPROFILE%`/`%APPDATA%` instead of `$HOME`. Note
`getenvFromBlock` returns `null` on Windows today (`io.zig:424`) and needs a
real implementation.

Exit: `fx --version`, help, and config read/write work on Windows. Capability
flags unchanged.

### Phase 2 — execution and process semantics

The core of the port. Replace pgid-based tree control with **Job Objects** —
`CreateJobObject` + `AssignProcessToJobObject` +
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` — which is the correct analogue of the
existing `kill(-pid, ...)` group termination in `direct_command.zig:731` and
`process_tree.zig`. Behind a process contract: spawn, timeout, terminate,
stdio piping, exit-status mapping. Add a PowerShell shell
strategy to `src/core/terminal/shell_resolver.zig`, which currently understands
only bash and zsh and hard-codes absolute POSIX paths (`shell_resolver.zig:19-34`).

**The provider vtable alone is not enough.** `background_process_provider` has
exactly one call site in `command_runner.zig` — line 603, inside
`spawnPreparedBackground` (`:592`). The foreground path never touches it:
`executeCommand` (`:540`) and `executeCommandInEnvironment` (`:556`) reach the
`executeProcess*` and `executeRawBash` family (`:1000`-`:1553`) directly. Since
v1 ships foreground approved commands and defers background ones, implementing
Job Objects behind that vtable alone would leave *everything v1 actually uses*
on the POSIX path. Extend the existing contract to cover foreground execution,
or introduce a shared process contract both paths call — do not add a third
independent path.

Keep `command_effect` on the approval path throughout.

Exit: shell execution and timeouts work. Flip `background_processes` for
Windows only once the Job Object path is proven.

### Phase 3 — auth end to end

OAuth browser handoff (Phase 1's `url_opener` arm), the profile-file token
store on Phase 1's private-state model, refresh, and logout.

Exit: both login flows complete on Windows.

### Phase 4 — interactive terminal (ConPTY)

A second backend against `contracts.zig`. This is where
`terminalSupportForOs(.windows)` finally becomes `.supported`.

Exit: interactive sessions, resize, and recovery.

### Phase 5 — CI and release

Add `x86_64-windows` to the cross-compile matrix in `.github/workflows/release.yml`. Zig
cross-compiles, so *building* is cheap — but packaging is not a matrix entry
away. The package step hard-codes the POSIX artifact
(`cp zig-out/bin/fx …` then `tar -czf`, `.github/workflows/release.yml:68-74`), and a Windows
target emits `zig-out/bin/fx.exe`. Following this phase literally fails at
packaging and never uploads a Windows artifact. Windows needs its own binary
name, archive format (`.zip`, not `.tar.gz`), and checksum wiring into the
release job.

Add a `windows-latest` runner to `.github/workflows/full-ci.yml`. It must **build and smoke-test
the binary**, not just run `zig build test`: the existing native jobs run
`fx help` and `fx status --json` and assert non-empty stdout with empty stderr
(`.github/workflows/full-ci.yml:59-75`). Unit tests alone never launch the product, so Windows
startup, console initialization, and stray-stderr regressions would all pass
the gate. The Windows job should exercise the same noninteractive happy path
against the freshly built `fx.exe`.

**The E2E suite cannot run on Windows as written.** It is Bun + tmux with
`FX_REQUIRE_TMUX: "1"` (`.github/workflows/full-ci.yml:113`), and the shard runner resets a tmux
server between files (`.github/workflows/full-ci.yml:213-216`). A Windows E2E harness is its own
project and should not gate v1.

---

## Testing

Platform-agnostic logic should stay testable everywhere by keeping OS
decisions in pure functions that take an `os_tag`, as
`nativeForOs`, `terminalSupportForOs`, `selectStorageBackend`,
`clipboardCommand`, and `launchUrl` already do. Those get Windows cases in the
existing table tests and run on Linux CI.

Genuinely OS-bound behavior — Job Object termination, ConPTY, ACL verification,
console raw mode — needs the `windows-latest` unit job from Phase 5 and cannot
be covered from Linux.

Guard against regressions on the existing platforms by not editing shared code
paths in place: add the seam, move macOS/Linux behavior behind it unchanged,
then add the Windows implementation.

---

## Open questions

- **Which shell is the Windows default?** PowerShell 7 (`pwsh`) is the better
  target but is not preinstalled; Windows PowerShell 5.1 is universal but
  differs materially. `cmd.exe` is the most predictable to quote for and the
  worst to use. This decision shapes `src/core/terminal/shell_resolver.zig` and the command
  classifier in `command_effect.zig`.
- **Is MSYS/Git-Bash a supported configuration or an accident?**
  `workspace_files.zig:262` already looks for `C:\Program Files\Git`.
- **Do we support Windows natively or steer users to WSL?** WSL is nearly free
  today. If WSL is the recommended path, this whole port becomes optional and
  should be justified on its own merits rather than assumed.
- **What is the minimum Windows version?** ConPTY requires 1809+; that decision
  belongs before Phase 4, not during it.

## Not verified here

The Phase 0 compile spike was not run — no Zig 0.16.0 toolchain is available in
this environment and `ziglang.org` is blocked by the network policy. Every
finding above is from static reading of the tree, with file and line citations
so each can be checked. Error *counts* and any claim about what the compiler
actually reports are deliberately absent.
