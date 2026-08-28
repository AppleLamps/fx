//! Corrects a Windows file handle that `std.Io` returns mislabelled.
//!
//! `std.Io.Dir.openFile` with `follow_symlinks = false` is how this codebase
//! refuses to be redirected by a symlink at the final path component. On
//! Windows the handle it returns cannot be read.
//!
//! Zig 0.16.0 opens the file with `.IO = .ASYNCHRONOUS` whenever
//! `follow_symlinks` is false — the same branch that sets
//! `OPEN_REPARSE_POINT`, at `Io/Threaded.zig:5033` — but hands back a `File`
//! whose `flags.nonblocking` is still false. The reader believes the handle is
//! synchronous, so it issues `NtReadFile` without an APC, gets
//! `STATUS_PENDING`, and reaches this:
//!
//! ```zig
//! .PENDING => unreachable, // unrecoverable: wrong File nonblocking flag
//! ```
//!
//! That aborts the process. It is not an error, so no `catch` at any call site
//! can intervene, and the abort happens on the *first read* rather than at the
//! open — far from the option that caused it.
//!
//! The handle is genuinely asynchronous, and the reader's nonblocking branch
//! is written for exactly that case: it issues the read with an APC and waits
//! for completion. Labelling the handle correctly is the whole fix. Nothing is
//! given up — the open stays a single atomic no-follow operation, rather than
//! being traded for a separate `statFile` check with a gap in the middle.
//!
//! This is applied by wrapping the `std.Io` vtable rather than by editing the
//! forty-odd call sites, for the same reason `darwin_process_spawn` wraps
//! `processSpawn`: one seam covers every caller, including the ones a sweep
//! would miss.
//!
//! It covers every caller that reaches I/O through `io_mod.getIo()`, which
//! installs the wrapper — including under test, where `getIo` returns a
//! wrapped `std.testing.io`. A no-follow open handed `std.testing.io`
//! *directly* bypasses it and will abort on Windows. Two test helpers did;
//! both now use `getIo()`, and new code should for the same reason.
//!
//! Verified under wine across every combination of `openFile` options this
//! codebase uses: `follow_symlinks = false` is the only one that reproduces
//! the abort, and correcting the flag makes all of them read. Whether real
//! Windows agrees has not been checked, but the flag that causes it is chosen
//! by Zig before any system call, so it should.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_original_vtable: ?*const std.Io.VTable = null;

/// Returns `original` unchanged off Windows.
pub fn wrap(original: std.Io) std.Io {
    if (comptime !supported) return original;
    if (wrapped_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.dirOpenFile = dirOpenFile;
        wrapped_original_vtable = original.vtable;
    }
    return .{
        .userdata = original.userdata,
        .vtable = &wrapped_vtable,
    };
}

fn dirOpenFile(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    const original = wrapped_original_vtable.?;
    var file = try original.dirOpenFile(userdata, dir, sub_path, options);
    // Only ever set the flag, never clear it. std has one reason to hand back
    // an asynchronous handle today; if it gains another, clearing the flag
    // here would recreate exactly the bug this corrects.
    if (needsNonblocking(options)) file.flags.nonblocking = true;
    return file;
}

/// The condition that decides the handle's I/O mode inside
/// `NtCreateFile`, mirrored here. Kept separate so it is checkable from a
/// POSIX host, where the call it mirrors cannot run.
pub fn needsNonblocking(options: std.Io.Dir.OpenFileOptions) bool {
    return !options.follow_symlinks;
}

test "only a no-follow open produces an asynchronous handle" {
    try std.testing.expect(needsNonblocking(.{ .mode = .read_only, .follow_symlinks = false }));
    try std.testing.expect(!needsNonblocking(.{ .mode = .read_only }));
    try std.testing.expect(!needsNonblocking(.{ .mode = .read_only, .follow_symlinks = true }));
}

test "the other options this codebase passes do not change the handle's mode" {
    // `resolve_beneath` and `allow_directory` were both suspected and both
    // cleared by probing; pinning them here keeps a later reader from
    // re-deriving that.
    try std.testing.expect(!needsNonblocking(.{ .mode = .read_only, .resolve_beneath = true }));
    try std.testing.expect(!needsNonblocking(.{ .mode = .read_only, .allow_directory = false }));
    try std.testing.expect(!needsNonblocking(.{
        .mode = .read_only,
        .allow_directory = false,
        .resolve_beneath = true,
    }));
    try std.testing.expect(needsNonblocking(.{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }));
}

test "the wrapper is a no-op off Windows" {
    if (comptime supported) return error.SkipZigTest;
    const original = std.testing.io;
    const wrapped = wrap(original);
    try std.testing.expectEqual(original.vtable, wrapped.vtable);
    try std.testing.expectEqual(original.userdata, wrapped.userdata);
}
