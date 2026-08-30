//! ConPTY pseudoconsole plumbing for a Windows terminal backend.
//!
//! POSIX allocates a terminal with `posix_openpt` and hands the slave to a
//! child. Windows has no such call. Its equivalent is **ConPTY**: a
//! pseudoconsole object created with `CreatePseudoConsole`, fed by one pipe and
//! read through another, and attached to a child through a process-thread
//! attribute rather than through file descriptors.
//!
//! Two things about the surrounding toolchain shape this module.
//!
//! **ConPTY is absent from `std.os.windows` in Zig 0.16.0** — no
//! `CreatePseudoConsole`, no `HPCON`, no `STARTUPINFOEX`, no
//! `PROC_THREAD_ATTRIBUTE_*`. All of it is bound here, as the Job Object API
//! was in phase 2. The three ConPTY entry points are resolved with
//! `GetProcAddress` rather than linked, because they arrived in Windows 10
//! 1809: a static import would turn an old Windows into a process that cannot
//! load, where a dynamic lookup is a clean `error.PseudoConsoleUnavailable`.
//!
//! **`std.process.spawn` cannot attach a pseudoconsole.** It builds a plain
//! `STARTUPINFOW`, and the attribute that binds a child to an `HPCON` only
//! travels in the extended form. So this module issues its own
//! `CreateProcessW`. That is why `commandLineAlloc` exists: `CreateProcessW`
//! takes one string, and the quoting rules that `CommandLineToArgvW` will
//! reverse are specific enough to be worth testing directly.
//!
//! Containment is not optional here. If the Job Object cannot be created or
//! assigned, the spawn fails and the still-suspended child is terminated,
//! rather than returning a shell whose tree nothing could later take down.
//! `command_runner` tolerates a missing job for a foreground command, which is
//! short-lived and collected; an interactive shell is neither.
//!
//! Owning the spawn has one benefit worth naming. Phase 2 recorded an open
//! race: `std.process.spawn` exposes no `CREATE_SUSPENDED`, so a child reached
//! its Job Object a moment after it started running, and anything it forked in
//! that window escaped. Here the `CreateProcessW` call is ours, so the child is
//! created suspended, assigned, and only then resumed. For pseudoconsole
//! children that race is closed.
//!
//! **What wine can and cannot prove.** `CreatePseudoConsole` resolves and
//! succeeds under wine, the attribute list builds and accepts
//! `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, and the child spawns. But no bytes
//! flow through the pty pipe — the child's output goes to the inherited
//! console instead — and `ResizePseudoConsole` fails. Wine creates the object
//! without wiring console I/O to it. So the setup path here is genuinely
//! exercised and the data path is not, which is why this module stops at the
//! pseudoconsole and its child rather than continuing into a session backend.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const windows_job = @import("../execution/windows_job.zig");

const Allocator = std.mem.Allocator;

const supported = builtin.os.tag == .windows;

// `callconv(pty_callconv)` lowers per target architecture: `win64` on x86_64, and
// `aarch64_aapcs_win` on ARM64 — which the LLVM backend rejects outside a
// Windows target. This module stays in the test registry so its pure-logic
// tests (quoting, COORD bounds, the STARTUPINFOEXW ABI) run everywhere, and
// building those tests for aarch64-linux is enough to force the calling
// convention through semantic analysis even though nothing here is ever
// called off Windows. Off-Windows the convention is therefore only required
// to be *a* valid one; on Windows it is `.winapi` exactly as before.
const pty_callconv: std.builtin.CallingConvention = if (supported) .winapi else .c;

const Error = error{
    PseudoConsoleUnavailable,
    PseudoConsoleCreateFailed,
    PseudoConsoleResizeFailed,
    PseudoConsoleSpawnFailed,
    /// The child started but could not be placed in a Job Object, so nothing
    /// would have been able to take its tree down later. Distinct from a spawn
    /// failure because the process did start; it is killed before this
    /// returns.
    PseudoConsoleContainmentFailed,
    InvalidPseudoConsoleSize,
};

/// A `HPCON`. Opaque to callers; only this module dereferences it.
const HPCON = windows.HANDLE;
const HRESULT = i32;

/// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, from `processthreadsapi.h`.
const proc_thread_attribute_pseudoconsole: usize = 0x00020016;

/// `EXTENDED_STARTUPINFO_PRESENT`.
const extended_startupinfo_present: windows.DWORD = 0x00080000;

/// `CREATE_SUSPENDED`, so the job assignment beats the child's first
/// instruction. See the module comment.
const create_suspended: windows.DWORD = 0x00000004;

/// `CREATE_UNICODE_ENVIRONMENT`. Required whenever an environment block is
/// passed, since ours is always UTF-16.
const create_unicode_environment: windows.DWORD = 0x00000400;

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: windows.DWORD,
    dwThreadId: windows.DWORD,
};

extern "kernel32" fn GetModuleHandleW(
    lpModuleName: ?windows.LPCWSTR,
) callconv(pty_callconv) ?windows.HMODULE;

extern "kernel32" fn GetProcAddress(
    hModule: windows.HMODULE,
    lpProcName: [*:0]const u8,
) callconv(pty_callconv) ?*anyopaque;

extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(pty_callconv) windows.BOOL;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *usize,
) callconv(pty_callconv) windows.BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *anyopaque,
    dwFlags: windows.DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(pty_callconv) windows.BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: *anyopaque,
) callconv(pty_callconv) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?windows.LPCWSTR,
    lpCommandLine: ?windows.LPWSTR,
    lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bInheritHandles: windows.BOOL,
    dwCreationFlags: windows.DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?windows.LPCWSTR,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(pty_callconv) windows.BOOL;

extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(pty_callconv) windows.DWORD;

extern "kernel32" fn TerminateProcess(
    hProcess: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(pty_callconv) windows.BOOL;

const CreatePseudoConsoleFn = *const fn (
    windows.COORD,
    windows.HANDLE,
    windows.HANDLE,
    windows.DWORD,
    *HPCON,
) callconv(pty_callconv) HRESULT;

const ResizePseudoConsoleFn = *const fn (HPCON, windows.COORD) callconv(pty_callconv) HRESULT;
const ClosePseudoConsoleFn = *const fn (HPCON) callconv(pty_callconv) void;

/// The three ConPTY entry points, resolved together or not at all.
const Procs = struct {
    create: CreatePseudoConsoleFn,
    resize: ResizePseudoConsoleFn,
    close: ClosePseudoConsoleFn,

    fn resolve() Error!Procs {
        if (comptime !supported) return error.PseudoConsoleUnavailable;
        const module = GetModuleHandleW(
            std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll"),
        ) orelse return error.PseudoConsoleUnavailable;
        return .{
            .create = @ptrCast(GetProcAddress(module, "CreatePseudoConsole") orelse
                return error.PseudoConsoleUnavailable),
            .resize = @ptrCast(GetProcAddress(module, "ResizePseudoConsole") orelse
                return error.PseudoConsoleUnavailable),
            .close = @ptrCast(GetProcAddress(module, "ClosePseudoConsole") orelse
                return error.PseudoConsoleUnavailable),
        };
    }
};

/// A terminal size in cells.
pub const Size = struct {
    columns: u16,
    rows: u16,

    /// `COORD` is a pair of signed 16-bit values and a pseudoconsole with a
    /// zero dimension is rejected by Windows, so both bounds are checked here
    /// rather than left to produce an opaque `HRESULT`.
    fn toCoord(self: Size) Error!windows.COORD {
        if (self.columns == 0 or self.rows == 0) return error.InvalidPseudoConsoleSize;
        if (self.columns > std.math.maxInt(i16) or self.rows > std.math.maxInt(i16)) {
            return error.InvalidPseudoConsoleSize;
        }
        return .{ .X = @intCast(self.columns), .Y = @intCast(self.rows) };
    }
};

/// A pseudoconsole and the two pipe ends the parent keeps.
///
/// `input` is written to reach the child's stdin; `output` is read to see what
/// the child drew. The other two ends belong to the pseudoconsole, which
/// duplicates them at creation, so they are closed here immediately — holding
/// them would keep `output` from ever reaching EOF.
pub const PseudoConsole = struct {
    handle: HPCON,
    input: windows.HANDLE,
    output: windows.HANDLE,
    procs: Procs,

    pub fn create(size: Size) Error!PseudoConsole {
        if (comptime !supported) return error.PseudoConsoleUnavailable;
        const coord = try size.toCoord();
        const procs = try Procs.resolve();

        var to_child_read: windows.HANDLE = undefined;
        var to_child_write: windows.HANDLE = undefined;
        if (!CreatePipe(&to_child_read, &to_child_write, null, 0).toBool()) {
            return error.PseudoConsoleCreateFailed;
        }
        errdefer windows.CloseHandle(to_child_write);

        var from_child_read: windows.HANDLE = undefined;
        var from_child_write: windows.HANDLE = undefined;
        if (!CreatePipe(&from_child_read, &from_child_write, null, 0).toBool()) {
            windows.CloseHandle(to_child_read);
            return error.PseudoConsoleCreateFailed;
        }
        errdefer windows.CloseHandle(from_child_read);

        var handle: HPCON = undefined;
        const hr = procs.create(coord, to_child_read, from_child_write, 0, &handle);

        // The pseudoconsole owns duplicates now; ours are dead weight, and
        // keeping `from_child_write` open would hold `output` short of EOF for
        // the life of the process.
        windows.CloseHandle(to_child_read);
        windows.CloseHandle(from_child_write);

        if (hr != 0) return error.PseudoConsoleCreateFailed;
        return .{
            .handle = handle,
            .input = to_child_write,
            .output = from_child_read,
            .procs = procs,
        };
    }

    /// Tells the child its window changed. The POSIX counterpart is
    /// `TIOCSWINSZ` plus `SIGWINCH`; ConPTY delivers both effects itself.
    pub fn resize(self: PseudoConsole, size: Size) Error!void {
        if (comptime !supported) return error.PseudoConsoleUnavailable;
        const coord = try size.toCoord();
        if (self.procs.resize(self.handle, coord) != 0) return error.PseudoConsoleResizeFailed;
    }

    /// Closing the pseudoconsole is what tells a well-behaved child to exit,
    /// so this is the graceful stop. It also releases the duplicated pipe
    /// ends, which is what finally lets a reader on `output` see EOF.
    pub fn close(self: *PseudoConsole) void {
        if (comptime !supported) return;
        self.procs.close(self.handle);
        windows.CloseHandle(self.input);
        windows.CloseHandle(self.output);
        self.* = undefined;
    }
};

/// A child attached to a pseudoconsole, always contained by a Job Object.
///
/// `job` is not optional, and that is a deliberate reversal. The first version
/// let containment fail softly, reasoning that a pty which refuses to open is
/// worse than one that opens uncontained — the trade `command_runner` made in
/// phase 2. That reasoning does not transfer. A foreground command is
/// short-lived and collected; this is an interactive shell whose only teardown
/// is the job, so an uncontained one leaks its whole tree on every timeout and
/// cancellation, with nothing able to reach it afterwards.
///
/// The failure is also detectable at the one moment it costs nothing: the
/// child is still suspended and has run no instruction, so refusing to
/// continue leaves nothing behind. `spawnAttached` terminates it and fails.
pub const Child = struct {
    process: windows.HANDLE,
    thread: windows.HANDLE,
    id: u32,
    job: windows_job.Job,

    /// Takes down the whole tree, not just the leader.
    ///
    /// That is the point of the job: on Windows, killing a process leaves its
    /// children running and still holding its pipes, which is exactly the
    /// deadlock phase 2 shipped and had to fix. Because containment is
    /// established before this type exists, the guarantee holds for every
    /// `Child`; there is no weaker path to fall back to.
    pub fn terminate(self: Child, exit_code: u32) void {
        if (comptime !supported) return;
        self.job.terminate(exit_code) catch {};
    }

    pub fn close(self: *Child) void {
        if (comptime !supported) return;
        self.job.close();
        windows.CloseHandle(self.thread);
        windows.CloseHandle(self.process);
        self.* = undefined;
    }
};

/// Serializes `argv` the way `CommandLineToArgvW` will read it back.
///
/// `CreateProcessW` takes one string, not a vector, so every argument boundary
/// has to survive a round trip through quoting rules that are easy to get
/// subtly wrong — and a terminal's first argument is a shell path that may
/// contain spaces, with arguments after it that may contain quotes. Caller owns
/// the result.
fn commandLineAlloc(alloc: Allocator, argv: []const []const u8) ![:0]u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    if (argv.len != 0) {
        // argv[0] follows different rules from the rest: backslashes in it are
        // never escapes, so a double quote there cannot be represented at all.
        const arg0 = argv[0];
        var needs_quotes = arg0.len == 0;
        for (arg0) |c| {
            if (c == '"') return error.InvalidCommandArgument;
            if (c <= ' ') needs_quotes = true;
        }
        if (needs_quotes) {
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, arg0);
            try buf.append(alloc, '"');
        } else {
            try buf.appendSlice(alloc, arg0);
        }

        for (argv[1..]) |arg| {
            try buf.append(alloc, ' ');
            const quote = for (arg) |c| {
                if (c <= ' ' or c == '"') break true;
            } else arg.len == 0;
            if (!quote) {
                try buf.appendSlice(alloc, arg);
                continue;
            }
            try buf.append(alloc, '"');
            var backslashes: usize = 0;
            for (arg) |byte| switch (byte) {
                '\\' => backslashes += 1,
                '"' => {
                    // A quote is escaped, and every backslash run in front of
                    // it doubles so it does not eat the escape.
                    try buf.appendNTimes(alloc, '\\', backslashes * 2 + 1);
                    try buf.append(alloc, '"');
                    backslashes = 0;
                },
                else => {
                    try buf.appendNTimes(alloc, '\\', backslashes);
                    try buf.append(alloc, byte);
                    backslashes = 0;
                },
            };
            // Backslashes immediately before the closing quote double too.
            try buf.appendNTimes(alloc, '\\', backslashes * 2);
            try buf.append(alloc, '"');
        }
    }

    return std.unicode.wtf8ToWtf16LeAllocZ(alloc, buf.items);
}

/// Starts `argv` attached to `pty`, contained by a fresh Job Object when one
/// can be established.
///
/// The child is created suspended so the job assignment lands before its first
/// instruction, then resumed. That ordering is the whole reason this spawn is
/// hand-rolled rather than delegated: `std.process.spawn` exposes no
/// `CREATE_SUSPENDED`, so phase 2 could only assign a child that was already
/// running, and anything it forked in that window escaped.
///
/// A job that cannot be created or assigned **fails the spawn**: the still
/// suspended child is terminated and an error returned, rather than handing
/// back a tree nothing could later reach. See `Child`.
pub fn spawnAttached(
    alloc: Allocator,
    pty: PseudoConsole,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !Child {
    if (comptime !supported) return error.PseudoConsoleUnavailable;
    if (argv.len == 0) return error.InvalidCommandArgument;

    const command_line = try commandLineAlloc(alloc, argv);
    defer alloc.free(command_line);

    const cwd_w: ?[:0]u16 = if (cwd) |path|
        try std.unicode.wtf8ToWtf16LeAllocZ(alloc, path)
    else
        null;
    defer if (cwd_w) |value| alloc.free(value);

    var size: usize = 0;
    // The documented way to learn the size: the first call is expected to fail
    // and only writes `size`.
    _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
    if (size == 0) return error.PseudoConsoleSpawnFailed;
    const attributes = try alloc.alignedAlloc(u8, .of(usize), size);
    defer alloc.free(attributes);

    if (!InitializeProcThreadAttributeList(attributes.ptr, 1, 0, &size).toBool()) {
        return error.PseudoConsoleSpawnFailed;
    }
    defer DeleteProcThreadAttributeList(attributes.ptr);

    if (!UpdateProcThreadAttribute(
        attributes.ptr,
        0,
        proc_thread_attribute_pseudoconsole,
        pty.handle,
        @sizeOf(HPCON),
        null,
        null,
    ).toBool()) {
        return error.PseudoConsoleSpawnFailed;
    }

    var startup: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
    startup.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    startup.lpAttributeList = attributes.ptr;

    var info: PROCESS_INFORMATION = undefined;
    if (!CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        // The pseudoconsole reaches the child through the attribute list, so
        // no handle needs inheriting — and inheriting none is the safer
        // default for a process that holds credentials.
        .FALSE,
        extended_startupinfo_present | create_suspended | create_unicode_environment,
        null,
        if (cwd_w) |value| value.ptr else null,
        &startup.StartupInfo,
        &info,
    ).toBool()) {
        return error.PseudoConsoleSpawnFailed;
    }
    errdefer {
        windows.CloseHandle(info.hThread);
        windows.CloseHandle(info.hProcess);
    }

    // Assign before resuming: this is the window phase 2 could not close.
    // Nothing below tolerates a missing job. The child is still suspended, so
    // failing here costs only a process that never ran an instruction.
    const job = windows_job.Job.create() catch {
        _ = TerminateProcess(info.hProcess, 1);
        return error.PseudoConsoleContainmentFailed;
    };
    errdefer job.close();
    job.assign(info.hProcess) catch {
        _ = TerminateProcess(info.hProcess, 1);
        return error.PseudoConsoleContainmentFailed;
    };

    if (ResumeThread(info.hThread) == std.math.maxInt(windows.DWORD)) {
        job.terminate(1) catch {};
        return error.PseudoConsoleSpawnFailed;
    }

    return .{
        .process = info.hProcess,
        .thread = info.hThread,
        .id = info.dwProcessId,
        .job = job,
    };
}

test "pseudoconsole support is advertised per platform" {
    try std.testing.expectEqual(builtin.os.tag == .windows, supported);
}

test "every entry point reports the same error for an unsupported platform" {
    // These three used to disagree — `create` said unavailable while `resize`
    // and `spawnAttached` reported runtime failures, which left a caller
    // unable to tell "this platform has no pseudoconsole" from "the
    // pseudoconsole broke". Platform gating is one answer.
    if (comptime supported) return error.SkipZigTest;
    try std.testing.expectError(
        error.PseudoConsoleUnavailable,
        PseudoConsole.create(.{ .columns = 80, .rows = 25 }),
    );
    const console: PseudoConsole = undefined;
    try std.testing.expectError(
        error.PseudoConsoleUnavailable,
        console.resize(.{ .columns = 80, .rows = 25 }),
    );
    try std.testing.expectError(
        error.PseudoConsoleUnavailable,
        spawnAttached(std.testing.allocator, console, &.{"cmd.exe"}, null),
    );
}

test "a size must fit COORD and have no zero dimension" {
    const ok = try (Size{ .columns = 80, .rows = 25 }).toCoord();
    try std.testing.expectEqual(@as(i16, 80), ok.X);
    try std.testing.expectEqual(@as(i16, 25), ok.Y);

    // The largest a COORD can carry.
    const max = try (Size{ .columns = 32767, .rows = 32767 }).toCoord();
    try std.testing.expectEqual(@as(i16, 32767), max.X);

    for ([_]Size{
        .{ .columns = 0, .rows = 25 },
        .{ .columns = 80, .rows = 0 },
        .{ .columns = 32768, .rows = 25 },
        .{ .columns = 80, .rows = 65535 },
    }) |bad| {
        try std.testing.expectError(error.InvalidPseudoConsoleSize, bad.toCoord());
    }
}

test "extended startup information matches the documented x64 ABI" {
    // `CreateProcessW` reads `cb` to decide whether an attribute list is
    // present, so a wrong size silently drops the pseudoconsole attachment
    // rather than failing.
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(windows.STARTUPINFOW));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(STARTUPINFOEXW));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(STARTUPINFOEXW, "lpAttributeList"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PROCESS_INFORMATION));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(PROCESS_INFORMATION, "dwProcessId"));
}

test "the pseudoconsole attribute and process flags are the documented values" {
    try std.testing.expectEqual(@as(usize, 0x00020016), proc_thread_attribute_pseudoconsole);
    try std.testing.expectEqual(@as(windows.DWORD, 0x00080000), extended_startupinfo_present);
    try std.testing.expectEqual(@as(windows.DWORD, 0x00000004), create_suspended);
    try std.testing.expectEqual(@as(windows.DWORD, 0x00000400), create_unicode_environment);
}

fn expectCommandLine(expected: []const u8, argv: []const []const u8) !void {
    const alloc = std.testing.allocator;
    const line = try commandLineAlloc(alloc, argv);
    defer alloc.free(line);
    const utf8 = try std.unicode.wtf16LeToWtf8Alloc(alloc, line);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings(expected, utf8);
}

test "command line serialization survives a round trip through CommandLineToArgvW rules" {
    try expectCommandLine("", &.{});
    try expectCommandLine("fx.exe", &.{"fx.exe"});
    try expectCommandLine("fx.exe a b", &.{ "fx.exe", "a", "b" });
    try expectCommandLine("fx.exe \"a b\"", &.{ "fx.exe", "a b" });
    try expectCommandLine("fx.exe \"\"", &.{ "fx.exe", "" });
    try expectCommandLine("\"\"", &.{""});
    // A backslash is ordinary unless it precedes a quote.
    try expectCommandLine("fx.exe C:\\dir\\file", &.{ "fx.exe", "C:\\dir\\file" });
    try expectCommandLine("fx.exe \"C:\\dir with space\\\\\"", &.{ "fx.exe", "C:\\dir with space\\" });
    try expectCommandLine("fx.exe \"say \\\"hi\\\"\"", &.{ "fx.exe", "say \"hi\"" });
    try expectCommandLine("fx.exe \"back\\\\\\\"slash\"", &.{ "fx.exe", "back\\\"slash" });
}

test "argv0 is quoted for spaces and rejected for quotes" {
    // Windows shell paths have spaces; `Program Files` is the reason this
    // matters rather than a hypothetical.
    try expectCommandLine(
        "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo",
        &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo" },
    );
    // Backslashes in argv0 are literal, so a quote there cannot be encoded at
    // all; refusing beats emitting a command line that splits somewhere else.
    try std.testing.expectError(
        error.InvalidCommandArgument,
        commandLineAlloc(std.testing.allocator, &.{"we\"ird.exe"}),
    );
}

test "the PowerShell invocation from the shell resolver serializes intact" {
    // `-Command` takes everything after it as command text, so the boundary
    // between it and the script is exactly what must not blur.
    try expectCommandLine(
        "powershell.exe -NoLogo -NoProfile -NonInteractive -Command \"echo 'a b' | cat\"",
        &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "echo 'a b' | cat" },
    );
}

test "a child cannot exist without containment" {
    // The type is the guarantee: `job` is not optional, so there is no way to
    // hold a `Child` whose tree `terminate` cannot reach. This pins that
    // against a future edit reintroducing the soft-failure path.
    const job_field = @FieldType(Child, "job");
    try std.testing.expectEqual(windows_job.Job, job_field);
    try std.testing.expect(@typeInfo(job_field) != .optional);
}
