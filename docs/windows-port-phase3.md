# Phase 3 — auth and secure storage on Windows

Status: implemented for the credential-storage half. `fx.exe` now reads a
stored API key on Windows, which it could not do before. The OAuth browser
round trip is **not** implemented, and the blocker for it sits below fx. See
[what is not done](#what-is-not-done).

The plan of record scoped phase 3 as "OAuth browser handoff, the profile-file
token store on phase 1's private-state model, refresh, and logout," exiting
when "both login flows complete on Windows." That exit is not met and cannot be
met from here. Findings 5 and 6 below explain why, and revise it.

Phase 3 also found that phase 1's exit criterion — "`fx --version`, help, and
config read/write work on Windows" — was only ever half true. Startup worked.
Config read never ran, because there was no home directory to read it from, and
the moment there was one it aborted the process. Both are fixed here.

## What was actually blocking a stored credential

Finding 3 of the plan said credential storage is already portable: the macOS
Keychain is not a blocker, and Windows selects the same profile-file backend
Linux ships on. That held up. `selectStorageBackend` returns `.profile_file`
for Windows and a test has always pinned it.

The finding also said the real blocker was one level down, in the private-state
permission model. That was right in spirit and wrong in detail. The permission
model was not what stood between Windows and a stored credential. Three other
things were, and they are sequential — each one only becomes visible once the
one before it is fixed.

### 1. Windows has no `HOME`

Every credential path resolved its directory with `io_mod.getenv("HOME")`,
which is null on Windows, so `native_secret_store` and `oauth_session`'s three
call sites returned `error.HomeNotSet` before touching the filesystem.

Measured, not assumed. A probe built for `x86_64-windows` and run under wine:

```
libc HOME=<null>
libc USERPROFILE=C:\users\root
libc APPDATA=C:\users\root\AppData\Roaming
```

A walk of the PEB environment block confirms no `HOME=` entry exists at all.

`io_mod.homeDir()` now resolves it: `HOME` first everywhere, then
`USERPROFILE` on Windows only. `HOME` keeps precedence there because Git Bash,
MSYS2, and Cygwin set it, and a user in one of those shells expects `~/.fx` and
fx's profile directory to be the same place. POSIX behavior is byte-identical —
the function returns exactly what `getenv("HOME")` returned. 52 call sites
moved to it.

`HOMEDRIVE` + `HOMEPATH` is deliberately not consulted: joining them needs an
allocator, and the result is a slice borrowed from the environment.

### 2. `syncVerifiedDir` refused on Windows

It returned `error.OperationUnsupported` unconditionally (`io.zig:589`).
`durableReplaceVerified` calls it as its final step and maps any failure to
`error.DurableReplacePostRenameFailed`, so even with a home directory the token
write failed after writing and renaming the file. The same call gates
`openOrCreateVerifiedPrivateChild` whenever it creates the directory, so `.fx`
could not be created either.

It is now backed by `FlushFileBuffers`, as the plan specified. One caveat is
load-bearing and is documented in the code: `FlushFileBuffers` needs a handle
with write access, and `std.Io.Dir` opens directories for traversal, so the
call fails. Confirmed by probe:

```
FlushFileBuffers(dir) failed err=ACCESS_DENIED
```

`ACCESS_DENIED` is therefore treated as "this handle cannot carry the barrier"
and reported as success. Every other failure maps onto the errors the POSIX
branch already returns, and that mapping is unit-tested from Linux —
`Win32Error` is a plain enum that exists on every target even though the call
producing one does not.

The tolerance is a real weakening. When `durableReplaceVerified` returns, the
file's *contents* are durable, because `FlushFileBuffers` on the file handle —
which does have write access — already ran. What is left unflushed is the
rename that published them, which rests on the NTFS metadata log. A crash
between the rename and that log reaching disk can lose the rename. The
alternative is the previous behavior, where no credential, session, or settings
file could be written at all.

### 3. `std.Io.Dir.setPermissions` panics on Windows

Found by running the binary, not by reading code. With a home directory
resolving, `fx mcp add` got far enough to create `C:\users\root\.fx` and then:

```
thread 36 panic: TODO implement dirSetPermissionsWindows
```

`std.Io.Dir.setPermissions` is `@panic("TODO implement
dirSetPermissionsWindows")` in Zig 0.16.0. Every caller already wraps it in a
`catch` that returns `error.PrivateStatePermissionsUnsupported` and continues —
but a panic is not an error, so the `catch` never runs and the process aborts.

`file_permissions.setDirPermissions` is the seam, and it is a no-op on Windows.
Nothing is lost that `verifies_confidentiality` does not already record:
Windows `Permissions` carries no owner/group/other classes to apply. The file
counterpart needs no seam — `std.Io.File.setPermissions` is implemented on
Windows, and `private_file` is `.default_file`, which is zero, the value
`NtSetInformationFile` reads as "leave the attributes alone."

The first sweep of this seam missed most of its call sites, because the audit
grep was truncated with `head -20` and acted on as if complete. A reviewer
caught `session_log.zig`, which every saved CLI and ACP session goes through —
so the fix for one abort would have shipped alongside a worse one. The audit is
now scripted and classifies every site by receiver type and by whether it sits
in a test, which is reproducible in a way reading twenty lines of grep is not.
All 11 production `Dir.setPermissions` calls are on the seam. The remaining
production calls all have `File` receivers, which need no seam.

## Finding 6 — a no-follow open returns a handle `std.Io` cannot read

This is the significant one, it is not confined to auth, and it was also found
by running the binary. With the three fixes above in place, `fx.exe status`
found the stored key and then:

```
thread 36 panic: reached unreachable code
```

The cause, from a debug build of a probe:

```
Io/Threaded.zig:9944 in readFilePositionalWindows
    .PENDING => unreachable, // unrecoverable: wrong File nonblocking flag
```

Zig 0.16.0 opens a file with `.IO = .ASYNCHRONOUS` whenever `follow_symlinks`
is false — the same branch that sets `OPEN_REPARSE_POINT`, at
`Io/Threaded.zig:5033` — but hands back a `File` whose `flags.nonblocking` is
still false. The reader believes the handle is synchronous, issues `NtReadFile`
without an APC, gets `STATUS_PENDING`, and reaches that `unreachable`.

Isolated to exactly one option, by probing each combination this codebase
passes:

| `openFile` options | read |
| --- | --- |
| `.mode = .read_only` | ok |
| `+ follow_symlinks = false` | **abort** |
| `+ allow_directory = false` | ok |
| `+ resolve_beneath = true` | ok |
| `+ allow_directory = false, resolve_beneath = true` | ok |
| all three, as the credential store opens it | **abort** |

`follow_symlinks = false` is how this codebase refuses to be redirected by a
symlink at the final path component. There are **42 such opens across 21
files** — session, config, auth, skills, images, workspace. Every one of them
aborts the process on its first read.

So `fx` had never read a file on Windows. Phase 1's "config read/write works"
was never exercised: `HOME` was null, so nothing reached a read. Phase 2's wine
smoke passed for the same reason — `--version`, `help`, and `status` read no
files. The port looked further along than it was.

**The fix is one flag.** The handle is genuinely asynchronous, and the reader's
nonblocking branch is written for exactly that case: it issues the read with an
APC and waits. Labelling the handle correctly is the whole repair, and it gives
up nothing — the open stays a single atomic no-follow operation rather than
being traded for a separate `statFile` check with a gap in the middle.

It is applied by wrapping the `std.Io` vtable's `dirOpenFile`, not by editing
42 call sites, for the same reason `darwin_process_spawn` wraps `processSpawn`:
one seam covers every caller, including the ones a sweep would miss. That
existing wrapper is why `process_io_for` was already the right place to put it.

Verified under wine: all six probe cases read successfully afterwards, and
`fx.exe status` reports `auth=stored API key (profile file)` — the first time
this program has read a file on Windows.

Streaming and positional, read and write, all four `std.Io` paths carry the
same `nonblocking` branch, so the correction is coherent for writes too.
`createFile` is unaffected: `CreateFileOptions` has no `follow_symlinks` field,
so it never takes the asynchronous branch.

## Finding 5 — Windows sockets are AFD, so the OAuth listener is blocked below fx

Phase 1 left `browser_callback.zig` with two Windows stubs — `listenerReady`
and `requestReadable` return "not ready", `setSocketTimeouts` does nothing — on
the reasoning that `std.posix.poll` is POSIX-only and the real implementation
was phase 3 work over `WSAPoll`. That reasoning named the wrong instrument, and
the right one is not reachable from here.

Zig 0.16 does not implement Windows sockets over ws2_32. `std.Io.Threaded`
drives them through **AFD** — `\Device\Afd` handles issued
`NtDeviceIoControlFile` calls with `IOCTL_AFD_*` codes. `netListenIpWindows`
uses `AFD.START_LISTEN`, `netAcceptWindows` uses `AFD.WAIT_FOR_LISTEN` and
`AFD.ACCEPT`, and socket options go through a private `socketOptionAfd`.

- **`WSAPoll` does not apply.** It expects a ws2_32 `SOCKET`, and these handles
  are not in Winsock's handle table. Nor does ws2_32 `setsockopt`, so
  `setSocketTimeouts` cannot be written that way either.
- **There is no non-blocking accept.** `netAcceptWindows` blocks in
  `WAIT_FOR_LISTEN`; unlike the POSIX path it never returns `WouldBlock`, which
  is the return the accept loop is built around.
- **`IOCTL_AFD_POLL` exists as a control code, but `AFD_POLL_INFO` is not
  declared in std and AFD is undocumented.** Writing it would mean putting
  undocumented kernel-interface structures into an auth path.

And none of it can be exercised here. Under wine, **no `std.Io.net` operation
works at all**:

```
listen  -> bindSocketIpAfd:    NTSTATUS 0xc00000cb BAD_DEVICE_TYPE
connect -> setSocketOptionAfd: NTSTATUS 0xc0000010 INVALID_DEVICE_REQUEST
                               (SO_REUSE_UNICASTPORT)
```

Wine's AFD does not implement the IOCTLs Zig's Windows networking issues
unconditionally. Almost certainly a wine gap rather than a Windows one —
`SO_REUSE_UNICASTPORT` is a real Windows 10 option and real AFD implements the
socket-option IOCTL — but the effect on this port is the same either way.

The correct design is `std.Io.async` plus `Future.cancel` rather than a
readiness poll: `netAcceptWindows` is already cancel-aware. That restructures
an auth-critical accept loop, and it could not be run once here. Phase 2 is the
reason not to write it blind — the Job Object deadlock in that phase lived
precisely in code no available harness could reach, and a reviewer found it
rather than a test.

**Revised phase 3 exit.** API-key login is unblocked on Windows. OAuth browser
sign-in is not, and closing it is not a phase 3 bullet: it needs an upstream
`std.Io.net` fix, a ws2_32-based listener, or the async restructure, and a real
Windows host to judge which.

## What the wine harness can and cannot prove

Phase 2 said a pass under wine is suggestive and a failure is always real. This
phase mapped the boundary properly, which is worth recording because it bounds
every future phase.

**Works under wine**, and is therefore genuinely exercised: process start, argv,
environment, path canonicalization, directory create and open and stat, file
create including `resolve_beneath`, `setPermissions` on files, write, `sync`,
rename, `statFile` with `nlink`, and — after finding 6 — reads.

**Not implemented by wine**, so untestable here regardless of what fx does:

- `NtLockFile` returns `STATUS_NOT_IMPLEMENTED`. Every advisory lock fails, so
  any write path that takes one (`fx mcp add`, session writes) cannot be driven
  to completion. This is why the *write* half of the credential path is
  verified by probing its primitives one by one rather than end to end.
- All AFD socket IOCTLs, as above. **Nothing network-shaped is verifiable** —
  not the OAuth listener, and not the model gateway either, which runs on
  `std.http.Client` over the same `std.Io.net`. Phase 5's `windows-latest`
  runner is the first place any socket in this program gets exercised.

## What is not done

- **OAuth browser sign-in on Windows.** Finding 5. The `url_opener` arm that
  launches the browser is implemented and tested; the loopback listener that
  receives the callback is not.
- **`fx setup` on Windows.** Masked key entry declines rather than echoing, the
  deliberate phase 1 choice. A key placed in the profile is read correctly, but
  there is no non-interactive command to write one, so the store half of the
  credential path is verified by primitives rather than end to end.
- **Refresh and logout are unexercised.** Both are OAuth-shaped and need the
  network.
- **`verifies_confidentiality` is still false.** Unchanged from phase 1, and
  still the right call: too permissive is no worse than today's `return true`,
  too restrictive breaks every private-state read, and wine's security stub
  cannot arbitrate. It belongs on phase 5's `windows-latest` runner.
- **Directory-sync durability has a documented gap.** `ReOpenFile` with write
  access might reach the real barrier; it needs a Windows host to judge.
- **Eight test-only `Dir.setPermissions` call sites remain unswept**
  (`settings_store.zig` x2, `profile_usage_store.zig` x4, `session_store.zig`
  x2). They will panic if the suite is ever run on Windows, which is phase 5's
  job. They are deliberately not routed through the seam: each one exists to
  establish a permission state the test then asserts against, and a silent
  no-op would leave the test asserting nothing. The right Windows behavior for
  them is `error.SkipZigTest`, which the seam cannot express.
