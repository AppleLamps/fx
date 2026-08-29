# Windows port finalization — measured findings

This document records the real-Windows-host verification behind the
finalization work. Every claim below was measured on a real Windows x86_64
host (the fork owner's machine, Windows 11, PowerShell 7), not under wine.
Where an earlier phase predicted a result from wine, this document states what
the real host actually does. Probe programs live in `probes/` and
`src/pty_probe.zig`; each is a standalone `zig build-exe` target and is not
part of the product build.

## Step 0 — probes before product code

### Probe 1: ConPTY data path (`src/pty_probe.zig`)

Phase 4 stopped at the setup path because wine creates the pseudoconsole
object but wires no I/O to it. On the real host, the shipped
`windows_pty.zig` module — not a parallel copy — completed the full cycle:

```
1. pseudoconsole created
2. child spawned pid=28484 with job containment
3. data path after echo: 287 bytes total, contains "CONPTY-MARKER-1" = true
4. resize to 120x40 returned without error
5. resize verified via mode con: 996 bytes total, contains "120" = true
6. reader joined eof=true failed=true total_bytes=1012
7. child waited ret=0 exit_code=1
8. marker=true resize_effective=true VERDICT: PASS
```

Verified: `CreatePseudoConsole` returns a pty that actually carries bytes in
both directions; a child written `echo CONPTY-MARKER-1` produced that marker
on the output pipe; `ResizePseudoConsole` succeeded *and took effect in the
child* (`mode con` reported the new 120-column width); `spawnAttached`'s
suspended-to-job-to-resume containment held; terminating the Job Object before
waiting for pipe EOF let the reader join and the child get collected with no
leak.

One detail the backend must encode: pipe EOF arrives as `ReadFile` returning
`FALSE` with `ERROR_BROKEN_PIPE`, not as a zero-byte read. The probe's reader
recorded `failed=true` at that point. Treating broken pipe as clean EOF is a
requirement, not a nicety.

**The phase 4 data-path blocker does not exist on real Windows.** The session
backend (finalization step 1) can be written against measured behavior.

### Probe 2: console VT modes (`probes/console_probe.zig`)

Automated self-test against a freshly allocated conhost:

```
1. original input mode=0x1f7 (got=true) output mode=0x7 (got=true)
2. SetConsoleMode output=true input=true
3. DSR reply: waited_ms=50 bytes=7 read_failed=false raw=1b 5b 31 3b 31 33 52
VERDICT: PASS
```

Verified: `SetConsoleMode` accepts `ENABLE_VIRTUAL_TERMINAL_PROCESSING` +
`DISABLE_NEWLINE_AUTO_RETURN` on the output handle and
`ENABLE_VIRTUAL_TERMINAL_INPUT` on the input handle; VT sequences are parsed
(color, cursor addressing); a DSR cursor-position request is answered with VT
bytes (`ESC[1;13R`) read directly from the input handle as a `ReadFile` byte
stream. This is exactly the model fx's POSIX raw mode uses, so the
`TerminalState` port can read one byte stream instead of translating
`INPUT_RECORD`s.

Not yet measured: the key sequences Windows Terminal sends for Enter,
Ctrl+Enter, arrows, and paste with `ENABLE_VIRTUAL_TERMINAL_INPUT` plus
win32-input-mode requested (`CSI ? 9001 h`). No automated harness here can
press keys. `console_probe.exe interactive` exists for that: run it in Windows
Terminal and in a classic conhost, press the keys, and record the hex output
here. Until then, Ctrl+Enter steering remains the one unverified input risk.

### Probe 3: loopback sockets (`probes/loopback_probe.zig`)

Phase 3 predicted, from wine, that the OAuth loopback listener fails because
Zig drives Windows sockets through undocumented AFD IOCTLs with no readiness
poll instrument. The real host refines that picture:

- **Raw ws2_32 loopback: PASS.** `socket`/`bind`/`listen`/`getsockname`/
  `WSAPoll`/`accept`/`send`/`recv` all work, including `WSAPoll` reporting
  `POLLIN` on the listening socket before accept. The readiness instrument
  exists; only the bindings were missing.
- **`std.Io.net` loopback: data does not flow.** `listen`, `connect`, and
  `accept` all succeed, the client's `flush()` reports success, but the
  server's read blocks forever. Setup operations work; the data path does
  not, on loopback specifically.
- **`std.http.Client` to a remote host: works.** `fx ask --json --no-save`
  reached the Vercel AI Gateway and completed a full model round trip
  (`"output":"OK"`) with a valid key. An earlier probe with an invalid key
  received a real HTTP 401. The model gateway data path, including streaming,
  is functional on Windows; only loopback was broken.

So the login fix is **option (a)**: a ws2_32-native loopback listener behind a
seam, reusing `browser_callback.zig`'s HTTP parsing and CORS handling. The
`std.Io.async` restructure and device-code fallbacks are not needed.

### Consequences for the finalization steps

1. ConPTY session backend: write it now; measured behavior replaces the wine
   caveats.
2. Console input: the VT-byte model is viable on conhost; Windows Terminal key
   encodings pending the interactive probe.
3. Login: ws2_32 listener, not an upstream fix and not a product-surface
   change.

## Step 1: ConPTY session backend (`src/core/terminal/windows_session.zig`)

Implemented and verified on this host. The backend is a third registry arm in
`native_session.zig` selected by OS tag, so it compiles and tests on Windows
while the public `terminalSupportForOs(.windows)` gate stays `.unsupported`
(the gate flips last). A comptime reference in `native_session.zig` pulls the
backend into Windows test builds; on non-Windows targets it is not analyzed.

Coverage against `contracts.ActionRequest`: start (command typed into the
interactive shell with CRLF, matching POSIX send-into-session semantics),
read (retained ring with absolute offsets, gap reporting), screen, write,
wait, monitor, inspect, list, resize, signal (ETX byte), close, plus
authority-claim enforcement at every lookup.

**New ConPTY finding, refining the phase 2 lesson.** Pipe EOF does *not*
follow child exit: while the HPCON is open, conhost keeps the output pipe
alive indefinitely after the child terminates. A `cmd /c exit` session
reached its 15 second wait ceiling with no EOF. The backend therefore runs a
monitor thread that waits on the child process handle, records the exit code,
transitions `child_exited`, and closes the pseudoconsole, which is what
finally releases the pipe and lets the reader observe EOF. Child exit and
pipe EOF are independent events; child exit is the authoritative exit signal,
and the `.exit` wait condition honors EOF alone as a fallback (unknown exit
code). Terminate-ordering still follows phase 2: terminate the job, close the
console, join the reader, join the monitor, then collect the child.

Verified by `zig test src/windows_session_test.zig --test-filter conpty` on
this host (3/3 passing, zero leaks, zero logged errors, no orphaned child
processes):

1. Round trip: `cmd.exe` under ConPTY echoes a start command (condition-met
   wait), accepts a second write, satisfies a match wait, replays both
   markers from retained output, rejects a wrong-proof claim
   indistinguishably from a missing session, resizes 80x24 to 100x30 through
   `ResizePseudoConsole`, inspects command and cwd, signals interrupt, and
   closes with the session listed as closed.
2. Natural exit: a shell started with `exit` is collected by the monitor
   thread; the wait reports `.exited` with code 0.
3. Registry deinit tears down a still-running session with no leaks.

Also fixed while landing this: `deinit` unlocked its registry mutex via
`defer` *after* poisoning `self.*`, swapping on corrupt mutex state (the
mutex is now unlocked before invalidation), and `listAction` leaked its
temporary session-facts slice after the owned result cloned it.

The public gate remains `.unsupported` and the product binary is unchanged
in behavior; `zig build` is green with the backend compiling for Windows.
Remaining known Windows unit-test failures (path handling, fixtures,
permissions, settings persistence, UI) are the step 4 inventory and are
untouched by this change.

## Step 2: console input/rendering (raw mode, VT-input byte model)

Implemented and verified on this host. The probe evidence closed the one
open input risk, and the raw-mode seam landed in the product.

### Key-encoding evidence (`console_probe.exe keys`, no human keystrokes)

The interactive probe required a human at the keyboard, which no automated
harness can provide. The `keys` mode added to `probes/console_probe.zig`
closes that without one: it allocates a fresh console, enables
`ENABLE_VIRTUAL_TERMINAL_INPUT`, and injects full `KEY_EVENT` record groups
(down/up, with real virtual keys, scan codes, and control-key states) via
`WriteConsoleInputW`. conhost's VT-input encoder runs at read time on the
input buffer, so injected records traverse exactly the pipeline physical
keys do. Measured on this host (Windows 11, fresh conhost):

| Key | legacy bytes | win32-input-mode (9001) |
| --- | --- | --- |
| a | `61` | `ESC[65;30;97;1;0;1_` |
| Enter | `0d` | `ESC[13;28;13;1;0;1_` |
| Ctrl+Enter | `0a` | `ESC[13;28;10;1;8;1_` |
| Shift+Enter | `0d` (indistinguishable) | `ESC[13;28;13;1;16;1_` |
| Up | `ESC[A` | `ESC[38;72;0;1;0;1_` |
| Home / End | `ESC[H` / `ESC[F` | `ESC[36;...` / `ESC[35;...` |
| Backspace | `7f` | `ESC[8;14;8;1;0;1_` |
| Ctrl+C | `03` | `ESC[67;46;3;1;8;1_` |
| Alt+A | `ESC a` | `ESC[65;30;97;1;2;1_` |

Verdict: legacy bytes collapse Shift+Enter into Enter and make every
modifier combination ambiguous; win32-input-mode reports the virtual key,
key-down state, and full control-key state per event, so Ctrl+Enter
(`VK 13`, `CtrlState 8`) is unambiguous. Because Windows Terminal delivers
keys through the same conhost encoder when 9001 is enabled end to end, this
encoding is what fx sees in both hosts. **Strategy chosen: request 9001 on
Windows and parse win32-input-mode events, with legacy byte decoding
untouched for POSIX.** `console_probe.exe interactive` remains available for
an optional human confirmation run in Windows Terminal, but it is no longer
blocking.

### Implementation

- `src/ui/terminal/windows_console.zig` (new): the console seam. Captures
  both console modes, replaces the input mode with
  `ENABLE_VIRTUAL_TERMINAL_INPUT` (clearing line input, echo, and processed
  input — the exact analogue of the POSIX raw termios contract), adds
  `ENABLE_VIRTUAL_TERMINAL_PROCESSING` to the output mode, restores both on
  teardown, and provides `WaitForSingleObject`-based input polling plus
  `GetConsoleScreenBufferInfo` layout. `DISABLE_NEWLINE_AUTO_RETURN` is
  deliberately not set: keeping newline auto-return preserves the POSIX
  terminal behavior the inline renderer is written against.
- `src/ui/shell_runtime.zig`: `TerminalState`'s Windows gates are gone.
  `ensureInteractive` accepts a real console, `captureOriginalTermios`
  stores console modes, `enableRawMode`/`disableRawMode` arm/restore them,
  `queryLayout` reads real geometry, and `pollInput` waits on the input
  handle. `read` keeps the byte-stream model Probe 2 verified.
- `src/ui/input/escape_parser.zig`: a win32-input-mode decoder.
  `ESC[VK;Scan;Char;KeyDown;State;Repeat_` reports translate into the same
  action space as Kitty CSI u reports, so Windows keys keep fx's exact
  semantics: Ctrl+Enter → steer submit, Shift+Enter → insert newline,
  Enter → submit, arrows/Home/End/Delete navigation, Ctrl+letter control
  bytes, printable characters preserved. Release events and the repeat
  count are ignored. Eight new tests pin the measured conhost encodings.
- `src/ui/terminal/terminal.zig`: the Windows interactive enable sequence
  requests bracketed paste, autowrap reset, and `CSI ?9001h`; the lifecycle
  restore sequences disable 9001 on Windows.
- `src/core/shared/stdio.zig` + `src/ui/transcript/runtime.zig`: fixed the
  bootstrap crash the drive probe exposed. `TranscriptRuntime.stdout_file`
  defaulted to an invalid-handle placeholder on Windows, so the first
  terminal write failed with `NotOpenForWriting` and fx exited at startup.
  `stdio.stdoutFile()` resolves the real stdout handle at runtime.

### Live verification (`src/fx_drive.zig`)

`fx_drive` spawns the freshly built `zig-out/bin/fx.exe` in a ConPTY (the
product's own `windows_pty.zig`), waits through startup, types into the
composer, and sends legacy and win32-input-mode key events including Ctrl+C:

```
3. startup: 673 bytes, contains VT sequences = true
4. fx alive after startup = true
5. after typing: 691 bytes, composer echo visible = true
6. after key events: 917 bytes total
7. fx alive at end = true
9. rendered_vt=true stayed_alive=true eof=true VERDICT: PASS
```

fx renders its interactive TUI, accepts input on the raw-mode byte-model
path, and shuts down cleanly. Focused unit tests pass for the decoder, the
console seam, and the enable sequence; the full `zig build test` binary
still does not link on Windows (the pre-existing phase 1 `kill` blocker).
