//! Probe: drive the freshly built fx.exe interactively under ConPTY.
//!
//! Build: zig build-exe src/fx_drive.zig -O ReleaseSafe
//!        -femit-bin=zig-out/probes/fx_drive
//!        (imports the product's own windows_pty.zig, like src/pty_probe.zig)
//!
//! This is the no-human happy-path proof for the Windows raw-mode seam:
//! spawn `fx.exe` in a pseudoconsole, wait through startup (raw mode, theme
//! detection, cursor probe, first frame), type characters into the composer,
//! press Escape and Ctrl+C, and verify fx rendered VT output and stayed
//! alive on the raw-mode byte-model input path. No prompt is submitted, so
//! no model request is made.

const std = @import("std");
const builtin = @import("builtin");
const pty = @import("../src/core/terminal/windows_pty.zig");

const windows = std.os.windows;

extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: u32,
) callconv(.winapi) u32;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *u32,
) callconv(.winapi) windows.BOOL;

const wait_object_0: u32 = 0;
const still_active: u32 = 259;

const ReaderShared = struct {
    io: std.Io,
    buffer: []u8,
    len: usize = 0,
    eof: bool = false,
    failed: bool = false,
    mutex: std.Io.Mutex = .init,

    fn snapshot(self: *ReaderShared) []u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.buffer[0..self.len];
    }
};

fn outputReader(handle: windows.HANDLE, shared: *ReaderShared) void {
    while (true) {
        shared.mutex.lockUncancelable(shared.io);
        const room = shared.buffer.len - shared.len;
        const offset = shared.len;
        shared.mutex.unlock(shared.io);
        if (room == 0) break;

        var n: u32 = 0;
        const ok = ReadFile(handle, shared.buffer.ptr + offset, @intCast(room), &n, null);
        shared.mutex.lockUncancelable(shared.io);
        defer shared.mutex.unlock(shared.io);
        if (!ok.toBool() or n == 0) {
            if (!ok.toBool()) shared.failed = true;
            shared.eof = true;
            return;
        }
        shared.len = offset + n;
    }
}

fn writeToPty(handle: windows.HANDLE, bytes: []const u8) !void {
    var written: u32 = 0;
    if (!WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null).toBool()) {
        return error.PtyWriteFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) {
        std.debug.print("probe is windows-only\n", .{});
        return;
    }
    const io = init.io;
    const alloc = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(alloc);
    const fx_path = if (args.len > 1)
        try alloc.dupe(u8, std.mem.sliceTo(args[1], 0))
    else
        "zig-out/bin/fx.exe";

    var console = try pty.PseudoConsole.create(.{ .columns = 120, .rows = 40 });
    std.debug.print("1. pseudoconsole created\n", .{});

    var child = try pty.spawnAttached(alloc, console, &.{fx_path}, null);
    std.debug.print("2. fx spawned pid={d} argv={s}\n", .{ child.id, fx_path });

    const buffer = try alloc.alloc(u8, 4 << 20);
    var shared = ReaderShared{ .io = io, .buffer = buffer };
    const reader = try std.Thread.spawn(.{}, outputReader, .{ console.output, &shared });

    // Startup: raw mode, theme detection, cursor probe, first frame.
    Sleep(4000);
    const startup = shared.snapshot();
    const rendered_vt = std.mem.find(u8, startup, "\x1b[") != null;
    std.debug.print("3. startup: {d} bytes, contains VT sequences = {}\n", .{
        startup.len, rendered_vt,
    });

    var alive: u32 = still_active;
    _ = GetExitCodeProcess(child.process, &alive);
    const startup_alive = alive == still_active;
    std.debug.print("4. fx alive after startup = {}\n", .{startup_alive});

    // Type into the composer (no submit), then exercise key events.
    try writeToPty(console.input, "hi");
    Sleep(600);
    const after_typing = shared.snapshot();
    const typed_echo = std.mem.find(u8, after_typing, "hi") != null;
    std.debug.print("5. after typing: {d} bytes, composer echo visible = {}\n", .{
        after_typing.len, typed_echo,
    });

    try writeToPty(console.input, "\x1b"); // Escape
    Sleep(400);
    try writeToPty(console.input, "\x1b[27;1;27;1;0;1_"); // win32-input-mode Escape
    Sleep(400);
    try writeToPty(console.input, "\x1b[65;30;97;1;0;1_"); // win32 'a' press
    Sleep(400);
    try writeToPty(console.input, "\x1b[67;46;3;1;8;1_"); // win32 Ctrl+C press
    Sleep(800);
    const final = shared.snapshot();
    std.debug.print("6. after key events: {d} bytes total\n", .{final.len});

    _ = GetExitCodeProcess(child.process, &alive);
    const end_alive = alive == still_active;
    std.debug.print("7. fx alive at end = {}\n", .{end_alive});

    child.terminate(1);
    console.procs.close(console.handle);
    reader.join();
    const wait = WaitForSingleObject(child.process, 10_000);
    var exit_code: u32 = 0;
    _ = GetExitCodeProcess(child.process, &exit_code);
    std.debug.print("8. teardown: reader eof={} failed={} child wait={} exit_code={d}\n", .{
        shared.eof, shared.failed, wait, exit_code,
    });
    windows.CloseHandle(console.input);
    windows.CloseHandle(console.output);
    child.close();

    const pass = rendered_vt and startup_alive and shared.eof and wait == wait_object_0;
    std.debug.print("9. rendered_vt={} stayed_alive={} eof={} VERDICT: {s}\n", .{
        rendered_vt, startup_alive, shared.eof, if (pass) "PASS" else "FAIL",
    });
    if (!pass) std.process.exit(1);
}
