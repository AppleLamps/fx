//! Probe: Windows console VT input/output support.
//!
//! Build: zig build-exe probes/console_probe.zig -O ReleaseSafe
//!        -femit-bin=zig-out/probes/console_probe.exe
//!
//! `console_probe.exe` allocates a fresh console and self-tests: it enables
//! VT output processing and VT input, writes color plus a DSR cursor-position
//! request, and checks that the reply arrives as VT bytes on the input handle.
//! This is what fx's raw-mode and renderer need and it is fully automatable.
//!
//! `console_probe.exe interactive` runs in the *current* terminal (Windows
//! Terminal or classic conhost), requests win32-input-mode, then hex-dumps
//! every input chunk until Ctrl+Q. This is for human verification of the key
//! sequences for Enter, Ctrl+Enter, arrows, and paste, which no automated
//! harness here can produce.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const enable_processed_output: u32 = 0x1;
const enable_virtual_terminal_processing: u32 = 0x4;
const disable_newline_auto_return: u32 = 0x8;
const enable_virtual_terminal_input: u32 = 0x200;

const std_input_handle: i32 = -10;
const std_output_handle: i32 = -11;

extern "kernel32" fn FreeConsole() callconv(.winapi) windows.BOOL;
extern "kernel32" fn AllocConsole() callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetStdHandle(nStdHandle: i32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    lpMode: *u32,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    dwMode: u32,
) callconv(.winapi) windows.BOOL;
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
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

fn writeConsole(handle: windows.HANDLE, bytes: []const u8) void {
    var written: u32 = 0;
    _ = WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null);
}

fn hexDump(bytes: []const u8) void {
    for (bytes) |b| std.debug.print("{x:0>2} ", .{b});
}

const ReaderShared = struct {
    handle: windows.HANDLE,
    buffer: []u8,
    len: usize = 0,
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
};

fn inputReader(shared: *ReaderShared) void {
    var n: u32 = 0;
    const ok = ReadFile(
        shared.handle,
        shared.buffer.ptr,
        @intCast(shared.buffer.len),
        &n,
        null,
    );
    if (!ok.toBool() or n == 0) {
        if (!ok.toBool()) shared.failed = true;
        return;
    }
    shared.len = n;
    shared.done.store(true, .seq_cst);
}

fn autoMode() !void {
    _ = FreeConsole();
    if (!AllocConsole().toBool()) {
        std.debug.print("AllocConsole failed\n", .{});
        return error.AllocConsoleFailed;
    }
    const h_in = GetStdHandle(std_input_handle) orelse return error.NoConsoleInput;
    const h_out = GetStdHandle(std_output_handle) orelse return error.NoConsoleOutput;

    var in_original: u32 = 0;
    var out_original: u32 = 0;
    const got_in = GetConsoleMode(h_in, &in_original).toBool();
    const got_out = GetConsoleMode(h_out, &out_original).toBool();
    std.debug.print("1. original input mode=0x{x} (got={}) output mode=0x{x} (got={})\n", .{
        in_original, got_in, out_original, got_out,
    });

    const out_set = SetConsoleMode(
        h_out,
        enable_processed_output |
            enable_virtual_terminal_processing |
            disable_newline_auto_return,
    ).toBool();
    const in_set = SetConsoleMode(h_in, enable_virtual_terminal_input).toBool();
    std.debug.print("2. SetConsoleMode output={} input={}\n", .{ out_set, in_set });

    // Color proves VT output processing; the DSR request proves the console
    // answers as VT bytes on the input handle, which is what raw-mode reading
    // needs.
    writeConsole(h_out, "\x1b[2J\x1b[31mVT-OUTPUT-OK\x1b[0m\x1b[6n");

    var buffer: [4096]u8 = undefined;
    var shared = ReaderShared{ .handle = h_in, .buffer = &buffer };
    const thread = try std.Thread.spawn(.{}, inputReader, .{&shared});
    var waited: usize = 0;
    while (!shared.done.load(.seq_cst) and waited < 60) : (waited += 1) {
        Sleep(50);
    }
    std.debug.print("3. DSR reply: waited_ms={d} bytes={d} read_failed={} raw=", .{
        waited * 50,
        shared.len,
        shared.failed,
    });
    hexDump(buffer[0..shared.len]);
    std.debug.print("\n", .{});
    thread.join();

    var pass = false;
    if (shared.len >= 4) {
        pass = buffer[0] == 0x1b and buffer[1] == '[' and buffer[shared.len - 1] == 'R';
    }
    std.debug.print("VERDICT: {s}\n", .{if (pass) "PASS" else "FAIL"});
    _ = FreeConsole();
    if (!pass) std.process.exit(1);
}

fn interactiveMode() !void {
    const h_in = GetStdHandle(std_input_handle) orelse return error.NoConsoleInput;
    const h_out = GetStdHandle(std_output_handle) orelse return error.NoConsoleOutput;

    var in_original: u32 = 0;
    var out_original: u32 = 0;
    _ = GetConsoleMode(h_in, &in_original);
    _ = GetConsoleMode(h_out, &out_original);

    _ = SetConsoleMode(
        h_out,
        enable_processed_output | enable_virtual_terminal_processing | disable_newline_auto_return,
    );
    _ = SetConsoleMode(h_in, enable_virtual_terminal_input);

    writeConsole(h_out,
        \\VT input probe. Type keys; every chunk is hex-dumped until Ctrl+Q.
        \\Requested win32-input-mode (CSI ? 9001 h) after this line.
        \\Press: Enter, Ctrl+Enter, arrows, Home, Backspace, paste text, F1, Ctrl+C, Alt+A.
        \\
    );
    writeConsole(h_out, "\x1b[?9001h");

    var buffer: [1024]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        const ok = ReadFile(h_in, &buffer, @intCast(buffer.len), &n, null);
        if (!ok.toBool() or n == 0) break;
        const chunk = buffer[0..n];
        writeConsole(h_out, "chunk: ");
        hexDump(chunk);
        writeConsole(h_out, " | ");
        for (chunk) |b| {
            if (b >= 0x20 and b < 0x7f) {
                writeConsole(h_out, &[1]u8{b});
            } else {
                writeConsole(h_out, ".");
            }
        }
        writeConsole(h_out, "\r\n");
        var quit = false;
        for (chunk) |b| {
            if (b == 0x11) quit = true; // Ctrl+Q
        }
        if (quit) break;
    }

    writeConsole(h_out, "\x1b[?9001l");
    _ = SetConsoleMode(h_in, in_original);
    _ = SetConsoleMode(h_out, out_original);
}

// ---- keys mode: injected records through the VT-input encoder ----
//
// WriteConsoleInputW appends KEY_EVENT records to the console input buffer and
// conhost encodes records into VT bytes when the app reads in
// ENABLE_VIRTUAL_TERMINAL_INPUT mode. Injected records therefore traverse the
// same record-to-VT pipeline physical keys do, which makes the key encodings
// measurable without a human at the keyboard.

const left_alt_pressed: u32 = 0x0002;
const left_ctrl_pressed: u32 = 0x0008;
const shift_pressed: u32 = 0x0010;
const key_event_record_type: u16 = 0x0001;
const generic_write: u32 = 0x40000000;
const create_always: u32 = 2;
const file_attribute_normal: u32 = 0x80;

extern "kernel32" fn WriteConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]const InputRecord,
    nLength: u32,
    lpNumberOfEventsWritten: ?*u32,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: u32,
) callconv(.winapi) u32;
extern "kernel32" fn PeekConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: [*]InputRecord,
    nLength: u32,
    lpNumberOfEventsRead: ?*u32,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;

const KeyEventRecord = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    UnicodeChar: u16,
    dwControlKeyState: u32,
};

const InputRecord = extern struct {
    EventType: u16,
    Event: KeyEventRecord,
};

fn keyRecord(down: bool, vk: u16, scan: u16, char: u16, state: u32) InputRecord {
    return .{ .EventType = key_event_record_type, .Event = .{
        .bKeyDown = windows.BOOL.fromBool(down),
        .wRepeatCount = 1,
        .wVirtualKeyCode = vk,
        .wVirtualScanCode = scan,
        .UnicodeChar = char,
        .dwControlKeyState = state,
    } };
}

fn pressRecords(vk: u16, scan: u16, char: u16, state: u32) [2]InputRecord {
    return .{
        keyRecord(true, vk, scan, char, state),
        keyRecord(false, vk, scan, char, state),
    };
}

fn modPressRecords(
    mod_vk: u16,
    mod_scan: u16,
    mod_state: u32,
    vk: u16,
    scan: u16,
    char: u16,
) [4]InputRecord {
    return .{
        keyRecord(true, mod_vk, mod_scan, 0, mod_state),
        keyRecord(true, vk, scan, char, mod_state),
        keyRecord(false, vk, scan, char, mod_state),
        keyRecord(false, mod_vk, mod_scan, 0, 0),
    };
}

const marker_vk: u16 = 0x5a; // Z
const marker_scan: u16 = 0x2c;
const marker_char: u16 = 'z';
var marker_records = pressRecords(marker_vk, marker_scan, marker_char, 0);

const Scenario = struct {
    name: []const u8,
    records: []const InputRecord,
};

const vk_v: u16 = 0x41;
const scenarios = [_]Scenario{
    .{ .name = "a", .records = &pressRecords(vk_v, 0x1e, 'a', 0) },
    .{ .name = "Enter", .records = &pressRecords(0x0d, 0x1c, 0x0d, 0) },
    .{ .name = "CtrlEnter", .records = &modPressRecords(0xa2, 0x1d, left_ctrl_pressed, 0x0d, 0x1c, 0x0a) },
    .{ .name = "ShiftEnter", .records = &modPressRecords(0xa0, 0x2a, shift_pressed, 0x0d, 0x1c, 0x0d) },
    .{ .name = "Up", .records = &pressRecords(0x26, 0x48, 0, 0) },
    .{ .name = "Down", .records = &pressRecords(0x28, 0x50, 0, 0) },
    .{ .name = "Left", .records = &pressRecords(0x25, 0x4b, 0, 0) },
    .{ .name = "Right", .records = &pressRecords(0x27, 0x4d, 0, 0) },
    .{ .name = "Home", .records = &pressRecords(0x24, 0x47, 0, 0) },
    .{ .name = "End", .records = &pressRecords(0x23, 0x4f, 0, 0) },
    .{ .name = "Backspace", .records = &pressRecords(0x08, 0x0e, 0x08, 0) },
    .{ .name = "Tab", .records = &pressRecords(0x09, 0x0f, 0x09, 0) },
    .{ .name = "Escape", .records = &pressRecords(0x1b, 0x01, 0x1b, 0) },
    .{ .name = "F1", .records = &pressRecords(0x70, 0x3b, 0, 0) },
    .{ .name = "CtrlC", .records = &modPressRecords(0xa2, 0x1d, left_ctrl_pressed, 0x43, 0x2e, 0x03) },
    .{ .name = "CtrlD", .records = &modPressRecords(0xa2, 0x1d, left_ctrl_pressed, 0x44, 0x20, 0x04) },
    .{ .name = "AltA", .records = &modPressRecords(0xa4, 0x38, left_alt_pressed, 0x41, 0x1e, 0x61) },
    .{ .name = "CtrlQ", .records = &modPressRecords(0xa2, 0x1d, left_ctrl_pressed, 0x51, 0x10, 0x11) },
};

const Logger = struct {
    handle: windows.HANDLE,

    fn writeBytes(self: Logger, bytes: []const u8) void {
        var written: u32 = 0;
        _ = WriteFile(self.handle, bytes.ptr, @intCast(bytes.len), &written, null);
    }

    fn line(self: Logger, text: []const u8) void {
        self.writeBytes(text);
        self.writeBytes("\r\n");
    }

    fn hexLine(self: Logger, prefix: []const u8, bytes: []const u8) void {
        self.writeBytes(prefix);
        for (bytes) |b| {
            var buf: [4]u8 = undefined;
            const printed = std.fmt.bufPrint(&buf, " {x:0>2}", .{b}) catch return;
            self.writeBytes(printed);
        }
        self.writeBytes("\r\n");
    }
};

// Collect the encoded bytes for one scenario. The scenario records were fully
// buffered by WriteConsoleInputW and every group ends with a marker key-down
// that encodes in both modes, so the first blocking ReadFile cannot starve.
// After it, keep draining while the buffer still holds records, then stop on a
// quiet window so late release-only bytes are not misattributed.
fn collectEncodedBytes(h_in: windows.HANDLE, out: []u8) []const u8 {
    var len: usize = 0;
    var read_buf: [512]u8 = undefined;
    var n_read: u32 = 0;
    const ok = ReadFile(h_in, &read_buf, @intCast(read_buf.len), &n_read, null);
    if (ok.toBool()) {
        const take = @min(@as(usize, n_read), out.len);
        @memcpy(out[0..take], read_buf[0..take]);
        len = take;
    }
    var quiet_windows: usize = 0;
    while (quiet_windows < 4 and len < out.len) {
        Sleep(60);
        var n_events: u32 = 0;
        var peek: [4]InputRecord = undefined;
        const has = PeekConsoleInputW(h_in, &peek, 4, &n_events);
        if (has.toBool() and n_events > 0) {
            quiet_windows = 0;
            const more = ReadFile(h_in, &read_buf, @intCast(read_buf.len), &n_read, null);
            if (!more.toBool()) break;
            const take = @min(@as(usize, n_read), out.len - len);
            @memcpy(out[len .. len + take], read_buf[0..take]);
            len += take;
        } else {
            quiet_windows += 1;
        }
    }
    return out[0..len];
}

fn runKeyPass(h_in: windows.HANDLE, h_out: windows.HANDLE, log: Logger, pass_name: []const u8, win32_input_mode: bool) void {
    log.line("== pass");
    log.line(pass_name);
    // Reset both mode requests deterministically at pass start.
    _ = SetConsoleMode(h_in, enable_virtual_terminal_input);
    writeConsole(h_out, "\x1b[?9001l");
    if (win32_input_mode) {
        writeConsole(h_out, "\x1b[?9001h");
    }
    Sleep(100);

    var out_buf: [1024]u8 = undefined;
    for (scenarios) |scenario| {
        _ = FlushConsoleInputBuffer(h_in);
        var written: u32 = 0;
        _ = WriteConsoleInputW(h_in, scenario.records.ptr, @intCast(scenario.records.len), &written);
        _ = WriteConsoleInputW(h_in, &marker_records, 2, &written);
        const bytes = collectEncodedBytes(h_in, &out_buf);
        log.hexLine(scenario.name, bytes);
    }
    writeConsole(h_out, "\x1b[?9001l");
}

fn keysMode(log_path_utf8: []const u8) !void {
    var log_path_wide: [512]u16 = undefined;
    const wide_len = @min(log_path_utf8.len, log_path_wide.len - 1);
    for (log_path_utf8[0..wide_len], 0..) |b, i| log_path_wide[i] = b;
    log_path_wide[wide_len] = 0;

    const log_handle = CreateFileW(
        @ptrCast(&log_path_wide),
        generic_write,
        0,
        null,
        create_always,
        file_attribute_normal,
        null,
    );
    if (@intFromPtr(log_handle) == @as(usize, @bitCast(@as(isize, -1)))) {
        return error.LogOpenFailed;
    }
    defer _ = CloseHandle(log_handle);
    const log = Logger{ .handle = log_handle };

    // A fresh console keeps the injected records away from any console the
    // host shell shares, and guarantees a plain conhost encoder for the
    // conhost pass.
    _ = FreeConsole();
    if (!AllocConsole().toBool()) {
        log.line("AllocConsole failed");
        return error.AllocConsoleFailed;
    }
    const h_in = GetStdHandle(std_input_handle) orelse return error.NoConsoleInput;
    const h_out = GetStdHandle(std_output_handle) orelse return error.NoConsoleOutput;

    var in_original: u32 = 0;
    var out_original: u32 = 0;
    _ = GetConsoleMode(h_in, &in_original);
    _ = GetConsoleMode(h_out, &out_original);
    log.line("console keys probe");
    log.hexLine("original_input_mode:", &std.mem.toBytes(@as(u32, @bitCast(in_original))));
    log.hexLine("original_output_mode:", &std.mem.toBytes(@as(u32, @bitCast(out_original))));

    _ = SetConsoleMode(
        h_out,
        enable_processed_output | enable_virtual_terminal_processing,
    );

    runKeyPass(h_in, h_out, log, "legacy (9001 off)", false);
    runKeyPass(h_in, h_out, log, "win32-input-mode (9001 on)", true);

    _ = SetConsoleMode(h_in, in_original);
    _ = SetConsoleMode(h_out, out_original);
    log.line("done");
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) {
        std.debug.print("probe is windows-only\n", .{});
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    if (args.len > 1 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "interactive")) {
        try interactiveMode();
    } else if (args.len > 1 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "keys")) {
        const log_path = if (args.len > 2)
            std.mem.sliceTo(args[2], 0)
        else
            "console_keys_log.txt";
        try keysMode(log_path);
    } else {
        try autoMode();
    }
}
