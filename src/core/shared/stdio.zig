//! Standard stream handles that are safe to name at comptime.
//!
//! On POSIX the standard streams are the well-known descriptors 0, 1, and 2,
//! so `std.posix.STDIN_FILENO` and friends are comptime constants and
//! `std.Io.File.stdout()` folds to one.
//!
//! On Windows they are `HANDLE`s stored in the process environment block.
//! `std.Io.File.stdout()` reads the PEB through inline assembly, which cannot
//! run at comptime, and `std.posix.fd_t` is `*anyopaque` rather than an
//! integer — so neither the descriptor constants nor `File.stdout()` can be a
//! struct-field default there.
//!
//! Use the `default_*` constants where a comptime default is required, and
//! the accessor functions to obtain a usable handle at runtime.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Placeholder standard-input handle for struct-field defaults.
///
/// Invalid on Windows: any use fails loudly instead of silently addressing
/// the wrong object. Resolve a real handle with `stdin()` at runtime.
pub const default_stdin: std.posix.fd_t = if (is_windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    std.posix.STDIN_FILENO;

/// Placeholder standard-output handle for struct-field defaults. See
/// `default_stdin` for the Windows caveat.
pub const default_stdout: std.posix.fd_t = if (is_windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    std.posix.STDOUT_FILENO;

/// Placeholder standard-error handle for struct-field defaults. See
/// `default_stdin` for the Windows caveat.
pub const default_stderr: std.posix.fd_t = if (is_windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    std.posix.STDERR_FILENO;

/// Placeholder standard-output file for struct-field defaults. See
/// `default_stdin` for the Windows caveat.
pub const default_stdout_file: std.Io.File = if (is_windows)
    .{ .handle = std.os.windows.INVALID_HANDLE_VALUE, .flags = .{ .nonblocking = false } }
else
    std.Io.File.stdout();

/// The process's standard input handle. Reads the PEB on Windows, so this
/// must be called at runtime rather than folded into a comptime value.
pub fn stdin() std.posix.fd_t {
    return std.Io.File.stdin().handle;
}

/// The process's standard output handle. See `stdin` for the Windows caveat.
pub fn stdout() std.posix.fd_t {
    return std.Io.File.stdout().handle;
}

/// The process's standard error handle. See `stdin` for the Windows caveat.
pub fn stderr() std.posix.fd_t {
    return std.Io.File.stderr().handle;
}

test "POSIX defaults keep the well-known descriptor numbers" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(std.posix.fd_t, 0), default_stdin);
    try std.testing.expectEqual(@as(std.posix.fd_t, 1), default_stdout);
    try std.testing.expectEqual(@as(std.posix.fd_t, 2), default_stderr);
}

test "runtime accessors agree with the POSIX defaults" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expectEqual(default_stdin, stdin());
    try std.testing.expectEqual(default_stdout, stdout());
    try std.testing.expectEqual(default_stderr, stderr());
}

test "default stdout file matches the POSIX standard output" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expectEqual(std.Io.File.stdout().handle, default_stdout_file.handle);
}
