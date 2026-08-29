# Windows Port Finalization Plan

This document is the implementation checklist for turning the
`AppleLamps/fx` Windows fork from a limited noninteractive build into a
supported Windows coding agent.

The phases are ordered by dependency. Do not enable a capability merely
because its low-level primitive compiles. Enable it only after its focused
tests, Windows-native integration test, and fresh-binary happy path pass.

## Completion rules

- [ ] Keep this checklist updated in the same change that completes a task.
- [ ] Build and test with Zig 0.16.0 or the version pinned by the repository.
- [ ] Run Windows-specific checks on a real Windows host, not only through Wine.
- [ ] Preserve Linux and macOS behavior while introducing platform seams.
- [ ] Add regression coverage before fixing a reproduced defect.
- [ ] Use `zig fmt --check src/` before every checkpoint.
- [ ] Use the freshly built `./zig-out/bin/fx.exe` for Windows smoke tests.
- [ ] Do not claim a phase complete until its acceptance gate passes.
- [ ] Keep Full CI green on Linux x86_64, Linux arm64, macOS x86_64, macOS
      arm64, and Windows x86_64 for the exact commit.

## Phase 1: Make the Windows test binary compile

Goal: make Windows-native unit tests a permanent CI gate before expanding the
supported surface.

### Compiler blockers

- [x] Capture the current `zig build test -Doptimize=ReleaseSafe` diagnostics
      in an issue or checkpoint note and group them by owning subsystem.
- [x] Fix Windows handle and PID formatting so pointer-valued process handles
      never use integer format specifiers.
- [x] Gate or abstract `std.c.pollfd`, `std.c.POLL`, and POSIX polling in test
      builds.
- [x] Gate or replace `waitpid` in background-runtime test declarations.
- [x] Replace unconditional `SIG.USR1` and `SIG.HUP` declarations with a typed
      platform-neutral signal or control-event contract.
- [x] Gate fork-based subagent test helpers on platforms that implement
      `fork`, without hiding portable subagent logic from Windows tests.
- [x] Remove Windows test analysis of POSIX `kill`, negative process-group IDs,
      and POSIX PID casts.
- [x] Gate or replace `fcntl` use in tmux test declarations.
- [ ] Run `zig build test -Doptimize=ReleaseSafe` on Windows and address every
      remaining compiler or test failure.

### CI gate

- [ ] Add `zig build test -Doptimize=ReleaseSafe` to the `native-windows` job
      in `.github/workflows/full-ci.yml`.
- [x] Remove the stale CI comment saying the Windows unit suite cannot compile.
- [ ] Update `docs/windows-port.md` and `docs/windows-port-phase5.md` with the
      measured final result.

### Phase 1 acceptance

- [x] `zig fmt --check src/` passes on Windows.
- [x] `zig build -Doptimize=ReleaseSafe` passes on Windows.
- [ ] `zig build test -Doptimize=ReleaseSafe` passes on Windows.
- [ ] The Windows Full CI job runs the unit suite and passes.

## Phase 2: Connect ConPTY to interactive fx

Goal: make the default `fx.exe` invocation start a usable interactive coding
session in Windows Terminal, PowerShell, and a standard console host.

### Terminal contract

- [ ] Define the Windows terminal backend against
      `src/core/terminal/contracts.zig` before wiring UI behavior.
- [ ] Keep the existing ConPTY primitive in `windows_pty.zig` as the low-level
      owner of pseudoconsole creation, resize, process containment, and handle
      cleanup.
- [ ] Implement Windows session start, inspect, wait, read, write, resize,
      signal, close, and recovery behavior.
- [ ] Define durable Windows session metadata without tmux server assumptions.
- [ ] Ensure every ConPTY child is created suspended, assigned to a Job Object,
      and only then resumed.
- [ ] Implement bounded output buffering and cursor semantics compatible with
      the existing terminal tool contract.
- [ ] Ensure process, thread, pipe, pseudoconsole, and Job Object handles close
      exactly once on success and every error path.

### UI integration

- [ ] Add a Windows terminal layout implementation using console APIs rather
      than `ioctl(TIOCGWINSZ)`.
- [ ] Route Windows resize events into the existing resize runtime.
- [ ] Connect ConPTY output to the shared terminal engine and transcript.
- [ ] Implement hosted child-terminal takeover and reliable restoration of the
      main fx view.
- [ ] Verify cursor visibility, bracketed paste behavior, Unicode width, color,
      alternate-screen ownership, and terminal title restoration.
- [ ] Remove the unconditional Windows `NotATerminal` return only after the
      Windows terminal state implementation is active.
- [ ] Change `terminalSupportForOs(.windows)` to `.supported` only after all
      Phase 2 tests pass.

### Phase 2 tests

- [ ] Add unit tests for ConPTY command-line quoting, environment blocks,
      resize bounds, handle cleanup, and containment failures.
- [ ] Add a Windows-native test that starts a shell, writes a command, reads its
      output, resizes the terminal, and closes the session.
- [ ] Add an interactive smoke test that launches the fresh binary, submits one
      local deterministic interaction, and exits cleanly.
- [ ] Verify stderr is clean and no child process remains after exit.

### Phase 2 acceptance

- [ ] Running `./zig-out/bin/fx.exe` opens the interactive UI on Windows.
- [ ] A user can enter, edit, submit, and cancel input.
- [ ] A hosted PowerShell session supports read, write, resize, and close.
- [ ] Exiting restores cursor, title, screen buffer, input modes, and terminal
      dimensions.

## Phase 3: Implement Windows console input and raw mode

Goal: provide correct keyboard, paste, interrupt, and masked-input behavior
without POSIX termios.

### Console mode abstraction

- [ ] Define a platform-neutral console input contract shared by CLI masked
      input and the interactive composer.
- [ ] Implement Windows mode capture with `GetConsoleMode`.
- [ ] Implement mode changes with `SetConsoleMode`, preserving unrelated input
      and output flags.
- [ ] Restore original modes on normal exit, error exit, cancellation, and
      process-level cleanup.
- [ ] Handle redirected stdin and stdout without assuming console handles.
- [ ] Support UTF-16 console input and convert it safely to fx's UTF-8 text
      model.
- [ ] Map Windows key events to existing composer actions, including arrows,
      navigation, deletion, Enter, Ctrl+Enter, Ctrl+C, Ctrl+O, and Ctrl+X.
- [ ] Implement paste handling without duplicating or truncating multiline
      content.

### Authentication input

- [ ] Replace the Windows `NotATerminal` path in API-key masked entry.
- [ ] Replace the Windows `NotATerminal` path in provider and team selection.
- [ ] Verify secrets are never echoed or written to debug logs.

### Phase 3 tests

- [ ] Add pure key-event translation tests.
- [ ] Add redirected-input tests.
- [ ] Add real-console tests for raw-mode entry and restoration.
- [ ] Add tests for Ctrl+C during idle input, model work, and tool execution.
- [ ] Add tests for Unicode, surrogate pairs, IME-produced text, and multiline
      paste.

### Phase 3 acceptance

- [ ] Interactive input works in Windows Terminal and the legacy console host.
- [ ] Masked API-key entry works and does not echo the secret.
- [ ] Ctrl+C and window close do not leave modified console modes behind.
- [ ] Redirected noninteractive commands remain functional.

## Phase 4: Complete browser-based OAuth on Windows

Goal: make Vercel, Codex, and Grok browser sign-in complete end to end.

### Listener implementation

- [ ] Define a cancellable listener-readiness abstraction independent of
      POSIX `poll`.
- [ ] Determine the supported Zig 0.16 Windows socket readiness mechanism and
      document why it is compatible with `std.Io.net` handles.
- [ ] Implement Windows listener readiness without busy waiting.
- [ ] Implement cancellable request readability with a finite deadline.
- [ ] Preserve protection against idle browser preconnects, unrelated requests,
      reset connections, invalid origins, and oversized requests.
- [ ] Remove Windows branches that always report the listener or request as not
      ready.
- [ ] Verify the callback listener binds only to loopback interfaces.
- [ ] Ensure listener and connection handles close on success, timeout,
      cancellation, and malformed requests.

### Provider flows

- [ ] Verify `fx login` for Vercel on Windows.
- [ ] Verify `fx login codex` on Windows.
- [ ] Verify `fx login grok` on Windows, including its CORS preflight.
- [ ] Verify refresh, session reload, and logout for every provider.
- [ ] Provide a clear fallback or actionable error if browser launching fails.

### Phase 4 tests

- [ ] Run browser-callback unit tests on Windows rather than skipping them.
- [ ] Add a deterministic loopback OAuth E2E test for each callback shape.
- [ ] Test cancellation before browser open, while awaiting callback, and while
      reading a connection.
- [ ] Confirm OAuth tokens never pass through Vercel AI Gateway when the direct
      provider route is selected.

### Phase 4 acceptance

- [ ] All three login commands complete on a real Windows host.
- [ ] Restarting fx reloads and refreshes the saved sessions.
- [ ] Logout removes only the selected provider's credentials.
- [ ] No listener, browser helper, or socket remains after completion.

## Phase 5: Verify private-state confidentiality with Windows ACLs

Goal: give Windows credentials, settings, sessions, and approvals the same
enforced confidentiality contract as POSIX mode `0600` and `0700`.

### DACL contract

- [ ] Define the accepted Windows security descriptor: current owner and
      SYSTEM only, with inheritance rules stated explicitly.
- [ ] Resolve and compare SIDs rather than localized account names.
- [ ] Reject unexpected allow ACEs, deny ACEs that invalidate owner access,
      unsafe inheritance, reparse-point escapes, and ownership mismatches.
- [ ] Implement private directory creation with an explicit secure DACL.
- [ ] Implement private file creation and replacement with an explicit secure
      DACL.
- [ ] Verify existing directories and files before trusting or modifying them.
- [ ] Preserve no-follow and single-link safety properties where Windows
      exposes equivalent information.
- [ ] Produce actionable diagnostics for unsafe state instead of silently
      weakening the check.
- [ ] Set `verifies_confidentiality` true on Windows only after verification is
      enforced.

### Durability

- [ ] Investigate reopening directory handles with write access so
      `FlushFileBuffers` can durably publish renames.
- [ ] Document and test the exact fallback if Windows cannot provide a directory
      metadata barrier through the selected API.
- [ ] Verify advisory locking on real Windows and repair unsupported lock paths.

### Phase 5 tests

- [ ] Test secure owner-and-SYSTEM ACLs.
- [ ] Test rejection of access granted to Users, Everyone, or another SID.
- [ ] Test inherited and explicit ACE combinations.
- [ ] Test unsafe owner, reparse point, hard-link, replacement, and race cases.
- [ ] Test credential, settings, session, permission-rule, and subagent-state
      persistence through the shared verified-directory implementation.

### Phase 5 acceptance

- [ ] Windows state writes are confidential, atomic, and recoverable.
- [ ] Unsafe preexisting state is rejected with an actionable message.
- [ ] Credential and session round trips pass on NTFS.
- [ ] `file_permissions.verifies_confidentiality` is true on Windows.

## Phase 6: Eliminate the foreground Job Object assignment race

Goal: guarantee command-tree containment before any child instruction runs.

### Spawn contract

- [ ] Define a shared Windows suspended-process primitive reusable by foreground
      commands and ConPTY.
- [ ] Create ordinary command children with `CREATE_SUSPENDED`.
- [ ] Configure stdin, stdout, stderr, environment, cwd, and creation flags
      without changing PowerShell invocation semantics.
- [ ] Create the Job Object before resuming the child.
- [ ] Treat Job Object creation or assignment failure as a launch failure.
- [ ] Resume the main thread only after containment succeeds.
- [ ] Remove the fallback that runs a foreground child without a Job Object.
- [ ] Ensure timeout, cancellation, error cleanup, and normal exit close every
      process and thread handle exactly once.
- [ ] Unify duplicated Win32 spawn and quoting logic where doing so preserves
      the ConPTY attribute-list requirements.

### Phase 6 tests

- [ ] Add a child fixture that immediately spawns a descendant before the parent
      begins normal work.
- [ ] Verify cancellation terminates the leader and immediate descendant.
- [ ] Verify timeout terminates the entire tree and output pipes reach EOF.
- [ ] Verify failed assignment never allows the suspended process to run.
- [ ] Stress the spawn and cancellation sequence repeatedly to expose races.

### Phase 6 acceptance

- [ ] No foreground command can execute outside its Job Object.
- [ ] Timeout and cancellation leave no descendants behind.
- [ ] Command output collection always terminates after tree cleanup.
- [ ] Linux and macOS process-group behavior remains unchanged.

## Phase 7: Add Windows-native deterministic E2E coverage

Goal: prevent Windows support from regressing after the port is enabled.

### Harness

- [ ] Create a Windows E2E harness that does not require tmux, Bash, `/dev`, or
      POSIX signals.
- [ ] Reuse existing fake Gateway, MCP, and OAuth fixtures where they are
      platform-neutral.
- [ ] Add Windows-specific process, console, and ConPTY fixtures where needed.
- [ ] Make test state isolated under a temporary `USERPROFILE` and workspace.
- [ ] Ensure every test cleans up processes, Job Objects, listeners, and files.
- [ ] Classify every new root E2E file in `scripts/pgso/corpus.json`.

### Required coverage

- [ ] CLI help, status, doctor, setup, models, permissions, and session commands.
- [ ] Interactive startup, prompt submission, steering, cancellation, resize,
      transcript, and clean exit.
- [ ] Foreground terminal execution, timeout, cancellation, Unicode output, and
      process-tree cleanup.
- [ ] Persistent terminal start, read, write, resize, monitor, close, and
      recovery.
- [ ] File read, write, edit, glob, grep, external-path permissions, drive
      letters, UNC paths, and case-insensitive path behavior.
- [ ] Settings, credentials, prompt history, sessions, approvals, and recovery.
- [ ] Gateway streaming, retry, cancellation, malformed responses, and context
      limits.
- [ ] Vercel, Codex, and Grok login, refresh, and logout.
- [ ] MCP stdio and HTTP transports, trust, authentication, cancellation, and
      cleanup.
- [ ] Subagent create, message, wait, cancel, persistence, and process cleanup.
- [ ] ACP startup, prompt flow, tool calls, cancellation, and session restore.
- [ ] Upgrade selection and Windows archive naming without modifying a real
      installation.

### CI integration

- [ ] Add Windows E2E shards or a duration-balanced Windows test matrix to Full
      CI.
- [ ] Run each test file in an isolated process.
- [ ] Capture stdout, stderr, exit status, process leaks, and temporary-state
      residue.
- [ ] Require Windows native build, unit tests, smoke tests, and E2E aggregate
      checks before the ship gate can report success.

### Phase 7 acceptance

- [ ] All supported Windows product paths have deterministic E2E owners.
- [ ] Windows E2E runs on every feature branch in Full CI.
- [ ] Test failures retain enough logs and artifacts for diagnosis.
- [ ] The suite passes repeatedly without leaked processes or flaky timeouts.

## Phase 8: Make fork-owned Windows releases independent

Goal: allow `AppleLamps/fx` to build and publish a Windows release without
requiring upstream-only macOS signing, Vercel Blob, website, or deployment
credentials.

### Workflow ownership

- [ ] Inventory every release, dev-release, CDN, signing, npm, and deployment
      secret expected by the fork.
- [ ] Decide which upstream publication jobs the fork owns, replaces, makes
      optional, or removes.
- [ ] Split Windows release publication from macOS signing and notarization.
- [ ] Ensure a Windows release can succeed when Apple signing environments are
      unavailable.
- [ ] Make CDN publication optional or replace it with fork-owned storage.
- [ ] Remove or condition fork workflows that call upstream deployment hooks.
- [ ] Ensure automated release notes identify `AppleLamps/fx` as the requesting
      repository.

### Windows packaging

- [ ] Build `x86_64-windows` in ReleaseSafe on a clean runner.
- [ ] Decide whether and when to add Windows arm64 as a supported artifact.
- [ ] Package `fx.exe`, `LICENSE`, and `THIRD_PARTY_NOTICES.md` in a reproducible
      ZIP archive.
- [ ] Generate and verify SHA-256 checksums.
- [ ] Add Authenticode signing with a fork-owned certificate, or prominently
      document unsigned SmartScreen behavior until signing is available.
- [ ] Test the downloaded archive on a clean Windows VM.
- [ ] Verify `fx upgrade` selects a fork-owned Windows artifact and validates its
      checksum before replacement.
- [ ] Ensure release links, issue links, package metadata, and runtime
      identification use `AppleLamps/fx`.

### Phase 8 acceptance

- [ ] A tagged fork release publishes the Windows archive without upstream
      secrets.
- [ ] A clean Windows machine can download, verify, extract, and run it.
- [ ] Upgrade works from one fork release to the next.
- [ ] Release failure cannot create a partial tag or misleading latest pointer.

## Final Windows ship gate

Do not describe Windows as supported until every item below is checked.

- [ ] Phases 1 through 8 are complete.
- [ ] Windows build, unit tests, smoke tests, and E2E tests pass for the exact
      current commit.
- [ ] Required Linux and macOS Full CI jobs pass for the same commit.
- [ ] The fresh Windows binary completes an interactive prompt and a terminal
      tool call end to end.
- [ ] Vercel, Codex, and Grok authentication paths are verified on Windows.
- [ ] Credentials and sessions pass DACL and persistence verification.
- [ ] Timeout and cancellation leave no process-tree or handle leaks.
- [ ] The release archive is tested on a clean Windows installation.
- [ ] README limitations are replaced with an accurate supported-feature and
      system-requirements section.
- [ ] `docs/windows-port.md` records the final architecture and no longer lists
      completed blockers as open.
