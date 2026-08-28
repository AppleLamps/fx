# Phase 4 — the ConPTY foundation

Status: the pseudoconsole layer is implemented and exercised as far as this
environment allows. The interactive session backend on top of it is **not**
implemented, and `terminalSupportForOs(.windows)` is deliberately still
`.unsupported`. This is a foundation, not a working terminal.

The plan scoped phase 4 as "a second backend against `contracts.zig`" with the
exit "interactive sessions, resize, and recovery." That exit is not met. What
follows is why the work stops where it does, and what it leaves behind.

## Finding 7 — ConPTY is absent from std, and `std.process.spawn` cannot reach it

POSIX allocates a terminal with `posix_openpt` and hands the slave to a child.
Windows has no such call. Its equivalent is a **pseudoconsole**: an object
created by `CreatePseudoConsole`, fed by one pipe and read through another, and
bound to a child through a *process-thread attribute* rather than through file
descriptors.

Two facts about the toolchain shape everything else:

**Nothing about ConPTY exists in `std.os.windows` as of Zig 0.16.0.** No
`CreatePseudoConsole`, no `HPCON`, no `STARTUPINFOEX`, no
`PROC_THREAD_ATTRIBUTE_*`. All of it is bound in `windows_pty.zig`, the way the
Job Object API was in phase 2.

**`std.process.spawn` cannot attach a pseudoconsole.** It builds a plain
`STARTUPINFOW` (`Io/Threaded.zig:15501`), and the attribute that binds a child
to an `HPCON` travels only in the extended form. So a Windows terminal backend
cannot delegate its spawn — it needs its own `CreateProcessW`, its own
attribute list, and its own argv-to-command-line serialization, because
`CreateProcessW` takes one string where POSIX takes a vector.

This is the same shape as finding 5 (sockets are AFD, not ws2_32): the plan
assumed a Windows implementation would be a substitution at the leaf, and in
both cases the substitution is not available at that level.

## What wine can and cannot prove here

Better than the socket case, and the boundary is exact. Probed against the
shipped module, not a parallel copy:

```
create ok
spawn ok pid=280 job=yes
resize failed: PseudoConsoleResizeFailed (expected under wine)
shipped-module
drained 0 bytes
DONE
```

**Works:** `CreatePseudoConsole` resolves and returns `S_OK`; the proc-thread
attribute list sizes, initializes, and accepts
`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`; `CreateProcessW` with
`EXTENDED_STARTUPINFO_PRESENT` spawns the child; the Job Object is created and
assigned; handles close without stranding anything.

**Does not work:** `ResizePseudoConsole` fails, and **no bytes flow through the
pty pipe** — the child's output (`shipped-module` above) went to the inherited
console instead. Wine creates the pseudoconsole object without wiring console
I/O to it.

So the *setup* path — which is where nearly all the fiddly Win32 code lives —
is genuinely exercised, and the *data* path is not. That is the line this phase
stops at, and it is why there is no session backend here: an
`executeAuthorized` implementation would be a large body of code whose central
behavior nothing available could run. Phase 2's Job Object deadlock is the
standing argument against writing that blind, and this phase supplied a second
data point before any product code existed — the first version of the ConPTY
probe deadlocked in exactly the same way, by waiting on the child before
draining the pipe.

## What landed

`src/core/terminal/windows_pty.zig`:

- **`PseudoConsole`** — `create`, `resize`, `close`, holding the two pipe ends
  the parent keeps. The other two are closed immediately after creation,
  because the pseudoconsole duplicates them and holding `from_child_write`
  would keep the output pipe from ever reaching EOF.
- **`commandLineAlloc`** — argv serialized so `CommandLineToArgvW` reads it
  back unchanged. `argv[0]` follows different rules from the rest (backslashes
  are never escapes there, so an embedded quote cannot be represented at all
  and is refused). Tested from POSIX against the cases that actually occur
  here: a shell path under `Program Files`, and the phase 2 PowerShell
  invocation whose `-Command` boundary must not blur.
- **`spawnAttached`** — attribute list, `STARTUPINFOEX`, `CreateProcessW`, Job
  Object, resume.
- The ConPTY trio is resolved with `GetProcAddress` rather than linked. It
  arrived in Windows 10 1809; a static import would make an older Windows a
  process that cannot load, where a dynamic lookup is a clean
  `error.PseudoConsoleUnavailable`.

Fifteen tests run on POSIX: platform gating, `COORD` bounds, the
`STARTUPINFOEXW` ABI (a wrong `cb` silently drops the pseudoconsole attachment
rather than failing), the documented flag values, and the command-line quoting
round trip.

### It closes phase 2's spawn-to-assignment race

Phase 2 recorded an open race: `std.process.spawn` exposes no
`CREATE_SUSPENDED`, so a child reached its Job Object a moment after it started
running, and anything it forked in that window escaped. Closing it needed
"suspended-start support in the spawn layer."

This phase owns a spawn layer. `spawnAttached` creates the child suspended,
assigns the job, and only then resumes. For pseudoconsole children the race is
closed. It remains open for `command_runner`'s foreground path, which still
goes through `std.process.spawn`.

### The module is deliberately not wired to anything

`windows_pty.zig` has no callers. It is registered in the test registry so it
compiles and its tests run on every platform, but nothing imports it into a
code path. That is intentional: the thing that would import it is the session
backend, and the reasons above are why that is not here yet. A reviewer seeing
an unused module is seeing the intended state.

## Also: the `url_open` capability flag, a phase 3 loose end

Phase 3 added the Windows arm to `url_opener` — `rundll32
url.dll,FileProtocolHandler` — and tested it, but left
`host.nativeForOs(.windows).url_open` false. The plan's own discipline is that
a phase ends by flipping the flag it earned, and phase 3 did not.

Flipped here, with the launcher first run under wine rather than assumed:

```
opener returned true
```

That is `rundll32` dispatching and exiting zero. It does not prove a browser
appeared — the wine prefix has no default browser — only that the launcher runs
and reports success rather than failing to spawn.

`background_commands` used `.windows` as its stand-in for a platform that
cannot open URLs, exactly as `url_opener`'s own test did in phase 3; it is
retargeted to `.freebsd`.

## What is not done

- **The terminal session backend.** `Registry` in `native_session.zig` is a
  comptime switch between a supported and an unsupported implementation; a
  Windows backend would be a third arm, so the 7,000-line POSIX backend is
  never compiled for Windows. The interface is small — `init`,
  `shutdownSessionsOnly`, `deinit`, `executeAuthorized`, `cancelAuthorized` —
  but `executeAuthorized` is the whole `contracts.Action` surface, and its
  central behavior is pty I/O, which is exactly what cannot be run here.
- **Session persistence and recovery.** The POSIX backend gets these from a
  tmux server that outlives fx. Windows has no equivalent, and the plan already
  says rebuilding it "should be scoped as its own project." Nothing here
  changes that assessment.
- **`terminalSupportForOs(.windows)` stays `.unsupported`.** Flipping it is the
  closing step of a working backend, never an opening move: it is a comptime
  compile gate, and flipping it early pulls the POSIX terminal backend into the
  Windows build and breaks it. Finding 1 of the plan, still true.
- **Resize is unverified.** Written, and it fails under wine for reasons that
  belong to wine, so a real Windows host is the first place it can be judged.
