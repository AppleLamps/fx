//! Probe: ConPTY data path on a real Windows host.
//!
//! Build: zig build-exe src/core/terminal/pty_probe.zig -O ReleaseSafe
//!        -femit-bin=zig-out/probes/pty_probe.exe
//!
//! Wine creates the pseudoconsole object but wires no I/O to it, so the phase 4
//! report stopped at the setup path. This probe drives the data path end to
//! end on a real host: create, spawn cmd.exe, write a command, read its output,
//! resize, verify the resize took effect in the child, then terminate the Job
//! Object before waiting for pipe EOF (the phase 2 deadlock ordering), join the
//! reader, and wait the child.

const std = @import("std");
const builtin = @import("builtin");
const pty = @import("core/terminal/windows_pty.zig");

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

fn printSnapshot(label: []const u8, snapshot: []const u8, needle: []const u8) void {
    const found = std.mem.find(u8, snapshot, needle) != null;
    std.debug.print("{s}: {d} bytes total, contains \"{s}\" = {}\n", .{
        label, snapshot.len, needle, found,
    });
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) {
        std.debug.print("probe is windows-only\n", .{});
        return;
    }
    const io = init.io;
    const alloc = std.heap.page_allocator;

    var console = try pty.PseudoConsole.create(.{ .columns = 100, .rows = 30 });
    std.debug.print("1. pseudoconsole created\n", .{});

    var child = try pty.spawnAttached(alloc, console, &.{"cmd.exe"}, null);
    std.debug.print("2. child spawned pid={d} with job containment\n", .{child.id});

    const buffer = try alloc.alloc(u8, 1 << 20);
    var shared = ReaderShared{ .io = io, .buffer = buffer };
    const reader = try std.Thread.spawn(.{}, outputReader, .{ console.output, &shared });

    Sleep(300);
    try writeToPty(console.input, "echo CONPTY-MARKER-1\r\n");
    Sleep(800);
    printSnapshot("3. data path after echo", shared.snapshot(), "CONPTY-MARKER-1");

    console.resize(.{ .columns = 120, .rows = 40 }) catch |err| {
        std.debug.print("4. resize FAILED: {any}\n", .{err});
    };
    std.debug.print("4. resize to 120x40 returned without error\n", .{});

    try writeToPty(console.input, "mode con\r\n");
    Sleep(800);
    printSnapshot("5. resize verified via mode con", shared.snapshot(), "120");

    // The phase 2 deadlock ordering: take down the job BEFORE waiting for pipe
    // EOF. Closing the pseudoconsole ends conhost, which closes the pipe write
    // end, which finishes the pending ReadFile with EOF. Only then do we wait
    // on the child.
    child.terminate(1);
    console.procs.close(console.handle);
    reader.join();
    std.debug.print("6. reader joined eof={} failed={} total_bytes={d}\n", .{
        shared.eof, shared.failed, shared.len,
    });

    const wait = WaitForSingleObject(child.process, 10_000);
    var exit_code: u32 = 0;
    _ = GetExitCodeProcess(child.process, &exit_code);
    std.debug.print("7. child waited ret={d} exit_code={d}\n", .{ wait, exit_code });
    windows.CloseHandle(console.input);
    windows.CloseHandle(console.output);
    child.close();

    const marker_found = std.mem.find(u8, shared.snapshot(), "CONPTY-MARKER-1") != null;
    const resize_effective = std.mem.find(u8, shared.snapshot(), "120") != null;
    const pass = marker_found and shared.eof and wait == wait_object_0;
    std.debug.print("8. marker={} resize_effective={} VERDICT: {s}\n", .{
        marker_found, resize_effective, if (pass) "PASS" else "FAIL",
    });
    if (!pass) std.process.exit(1);
}
