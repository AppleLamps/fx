//! Windows console raw-mode seam behind `TerminalState`.
//!
//! Probe-verified model (see docs/windows-port-finalization.md): with
//! `ENABLE_VIRTUAL_TERMINAL_INPUT` the input handle behaves as a VT byte
//! stream through `ReadFile`, conhost answers output requests with VT bytes,
//! and win32-input-mode (`CSI ?9001 h`) reports every key event with its
//! virtual key and modifier state, which keeps Ctrl+Enter distinguishable
//! from Enter.
//!
//! Raw mode here mirrors the POSIX termios path in `shell_runtime.zig`:
//! capture both console modes, replace the input mode with the VT-input byte
//! model, add VT processing to the output mode, and restore both on teardown.
//! `DISABLE_NEWLINE_AUTO_RETURN` is deliberately not set: keeping newline
//! auto-return preserves the POSIX terminal behavior the inline renderer is
//! written against.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../core/shared/types.zig");
const ui_terminal = @import("terminal.zig");

const windows = std.os.windows;

const enable_processed_input: u32 = 0x0001;
const enable_line_input: u32 = 0x0002;
const enable_echo_input: u32 = 0x0004;
const enable_virtual_terminal_processing: u32 = 0x0004;
const enable_virtual_terminal_input: u32 = 0x0200;

const wait_object_0: u32 = 0x00000000;
const wait_timeout: u32 = 0x00000102;

const std_input_handle: windows.DWORD = @bitCast(@as(i32, -10));
const std_output_handle: windows.DWORD = @bitCast(@as(i32, -11));

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    lpMode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    dwMode: windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *ConsoleScreenBufferInfo,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

const Coord = extern struct {
    x: i16,
    y: i16,
};

const SmallRect = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

const ConsoleScreenBufferInfo = extern struct {
    dwSize: Coord,
    dwCursorPosition: Coord,
    wAttributes: u16,
    srWindow: SmallRect,
    dwMaximumWindowSize: Coord,
};

pub const ConsoleModes = struct {
    input: u32 = 0,
    output: u32 = 0,
    captured: bool = false,
};

pub const WaitOutcome = enum {
    readable,
    timeout,
    failed,
};

fn inputHandle() windows.HANDLE {
    return GetStdHandle(std_input_handle);
}

fn outputHandle() windows.HANDLE {
    return GetStdHandle(std_output_handle);
}

// The byte model conhost's VT-input encoder exposes on the input handle. The
// cooked-input flags (line, echo, processed) must all be clear so key events
// arrive as raw encoded bytes, matching the POSIX raw termios contract.
pub const raw_input_mode: u32 = enable_virtual_terminal_input;

pub fn ensureInteractive() !void {
    var mode: windows.DWORD = 0;
    if (!GetConsoleMode(inputHandle(), &mode).toBool()) return error.NotATerminal;
    if (!GetConsoleMode(outputHandle(), &mode).toBool()) return error.NotATerminal;
}

pub fn captureOriginalModes() !ConsoleModes {
    var input: windows.DWORD = 0;
    if (!GetConsoleMode(inputHandle(), &input).toBool()) return error.NotATerminal;
    var output: windows.DWORD = 0;
    if (!GetConsoleMode(outputHandle(), &output).toBool()) return error.NotATerminal;
    return .{
        .input = input,
        .output = output,
        .captured = true,
    };
}

pub fn enableRawMode(original: ConsoleModes) !void {
    if (!SetConsoleMode(inputHandle(), raw_input_mode).toBool()) {
        return error.RawModeUnavailable;
    }
    // Keep every original output capability and add VT processing so the
    // renderer's existing sequences are parsed instead of echoed.
    const output_mode = original.output | enable_virtual_terminal_processing;
    _ = SetConsoleMode(outputHandle(), output_mode);
}

pub fn restoreModes(original: ConsoleModes) void {
    if (!original.captured) return;
    _ = SetConsoleMode(inputHandle(), original.input);
    _ = SetConsoleMode(outputHandle(), original.output);
}

pub fn pollConsoleInput(timeout_ms: i32) WaitOutcome {
    const wait_ms: windows.DWORD = if (timeout_ms < 0)
        std.math.maxInt(u32)
    else
        @intCast(timeout_ms);
    return switch (WaitForSingleObject(inputHandle(), wait_ms)) {
        wait_object_0 => .readable,
        wait_timeout => .timeout,
        else => .failed,
    };
}

pub fn queryLayout(footer_rows: u16) !types.Layout {
    var info: ConsoleScreenBufferInfo = undefined;
    if (!GetConsoleScreenBufferInfo(outputHandle(), &info).toBool()) {
        return error.UnableToReadTerminalSize;
    }
    const cols: u16 = @intCast(info.srWindow.right - info.srWindow.left + 1);
    const rows: u16 = @intCast(info.srWindow.bottom - info.srWindow.top + 1);
    return ui_terminal.layoutFromSize(rows, cols, footer_rows);
}

test "raw input mode clears every cooked-input flag" {
    try std.testing.expectEqual(enable_virtual_terminal_input, raw_input_mode);
    try std.testing.expectEqual(@as(u32, 0), raw_input_mode & enable_processed_input);
    try std.testing.expectEqual(@as(u32, 0), raw_input_mode & enable_line_input);
    try std.testing.expectEqual(@as(u32, 0), raw_input_mode & enable_echo_input);
}
