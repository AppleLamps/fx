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

pub const supported = builtin.os.tag == .windows;

pub const Error = error{
    PseudoConsoleUnavailable,
    PseudoConsoleCreateFailed,
    PseudoConsoleResizeFailed,
    PseudoConsoleSpawnFailed,
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
) callconv(.winapi) ?windows.HMODULE;

extern "kernel32" fn GetProcAddress(
    hModule: windows.HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *usize,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *anyopaque,
    dwFlags: windows.DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: *anyopaque,
) callconv(.winapi) void;

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
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.winapi) windows.DWORD;

const CreatePseudoConsoleFn = *const fn (
    windows.COORD,
    windows.HANDLE,
    windows.HANDLE,
    windows.DWORD,
    *HPCON,
) callconv(.winapi) HRESULT;

const ResizePseudoConsoleFn = *const fn (HPCON, windows.COORD) callconv(.winapi) HRESULT;
const ClosePseudoConsoleFn = *const fn (HPCON) callconv(.winapi) void;

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
    pub fn toCoord(self: Size) Error!windows.COORD {
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
        if (comptime !supported) return error.PseudoConsoleResizeFailed;
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

/// A child attached to a pseudoconsole, contained by a Job Object.
pub const Child = struct {
    process: windows.HANDLE,
    thread: windows.HANDLE,
    id: u32,
    job: ?windows_job.Job,

    /// Takes down the whole tree, not just the leader: on Windows killing a
    /// process leaves its children running and holding its pipes, which is the
    /// deadlock phase 2 shipped and had to fix.
    pub fn terminate(self: Child, exit_code: u32) void {
        if (comptime !supported) return;
        if (self.job) |job| job.terminate(exit_code) catch {};
    }

    pub fn close(self: *Child) void {
        if (comptime !supported) return;
        if (self.job) |job| job.close();
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
pub fn commandLineAlloc(alloc: Allocator, argv: []const []const u8) ![:0]u16 {
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

/// Starts `argv` attached to `pty`, contained by a fresh Job Object.
///
/// The child is created suspended so the job assignment lands before its first
/// instruction, then resumed. That ordering is the whole reason this spawn is
/// hand-rolled rather than delegated.
pub fn spawnAttached(
    alloc: Allocator,
    pty: PseudoConsole,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !Child {
    if (comptime !supported) return error.PseudoConsoleSpawnFailed;
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
    var job: ?windows_job.Job = windows_job.Job.create() catch null;
    if (job) |created| {
        created.assign(info.hProcess) catch {
            created.close();
            job = null;
        };
    }

    if (ResumeThread(info.hThread) == std.math.maxInt(windows.DWORD)) {
        if (job) |created| {
            created.terminate(1) catch {};
            created.close();
        }
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

test "creating a pseudoconsole off Windows reports unavailable rather than trapping" {
    if (comptime supported) return error.SkipZigTest;
    try std.testing.expectError(
        error.PseudoConsoleUnavailable,
        PseudoConsole.create(.{ .columns = 80, .rows = 25 }),
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

test "spawning off Windows reports failure rather than trapping" {
    if (comptime supported) return error.SkipZigTest;
    const pty: PseudoConsole = undefined;
    try std.testing.expectError(
        error.PseudoConsoleSpawnFailed,
        spawnAttached(std.testing.allocator, pty, &.{"cmd.exe"}, null),
    );
}
