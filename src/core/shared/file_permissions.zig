//! Platform-neutral predicates over `std.Io.File.Permissions`.
//!
//! POSIX exposes mode bits through `toMode`/`fromMode`. Windows exposes a
//! `FILE_ATTRIBUTE` bitmask with no owner/group/other classes and neither
//! accessor, so call sites that reached for mode bits directly did not
//! compile for Windows. They go through this module instead.
//!
//! Every POSIX branch below is the exact bit test it replaced, so macOS and
//! Linux behavior is unchanged.
//!
//! Note that `Permissions.readOnly`, `setReadOnly`, and `toAttributes` are
//! unusable on Windows in Zig 0.16.0 and must not be called from portable
//! code: they reference `windows.FILE_ATTRIBUTE_READONLY`, which no longer
//! exists, and `toAttributes` bit-casts the permission enum into
//! `windows.FILE.ATTRIBUTE` — the `PS_ATTRIBUTE` process-attribute struct,
//! unrelated to file attributes. On Windows only the enum tags and
//! `@intFromEnum` are sound, which is why the predicates below never reach
//! for those helpers.

const std = @import("std");
const builtin = @import("builtin");

pub const Permissions = std.Io.File.Permissions;

const is_windows = builtin.os.tag == .windows;

/// Whether the confidentiality predicates in this module actually verify
/// confidentiality on the target platform.
///
/// False on Windows: `Permissions` there carries no owner/group/other
/// classes, so `isPrivateToOwner`, `isExactlyPrivateFile`, and
/// `isExactlyPrivateDir` have nothing to inspect. Private state on Windows
/// currently rests on the ACL inherited from the user profile directory,
/// which this module does not read — those predicates permit rather than
/// verify. Replacing the Windows branches with a real DACL check (owner and
/// SYSTEM only) is the remaining Windows private-state work, and flipping
/// this constant is how that work announces itself.
pub const verifies_confidentiality = !is_windows;

/// Permissions for a newly created private file: `0o600` on POSIX.
pub const private_file: Permissions = if (is_windows) .default_file else .fromMode(0o600);

/// Permissions for a newly created private directory: `0o700` on POSIX.
pub const private_dir: Permissions = if (is_windows) .default_dir else .fromMode(0o700);

/// True when no class other than the owner holds any access (`0o077` clear).
pub fn isPrivateToOwner(permissions: Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o077 == 0;
}

/// True when the owner holds the write bit (`0o200` set).
///
/// Windows permits: the read-only attribute is not consulted because std's
/// accessor for it does not compile there (see the module comment).
pub fn isOwnerWritable(permissions: Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o200 != 0;
}

/// True when any class holds a write bit (`0o222` set).
///
/// Windows permits, for the same reason as `isOwnerWritable`.
pub fn isWritable(permissions: Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o222 != 0;
}

/// True when neither group nor other holds a write bit (`0o022` clear).
///
/// Weaker than `isPrivateToOwner`: read access by other classes is allowed.
pub fn isProtectedFromGroupAndOther(permissions: Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o022 == 0;
}

/// True when the permission bits are exactly `0o600`.
pub fn isExactlyPrivateFile(permissions: Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o777 == 0o600;
}

/// True when the permission bits are exactly `0o700`.
pub fn isExactlyPrivateDir(permissions: Permissions) bool {
    if (comptime is_windows) return true;
    return permissions.toMode() & 0o777 == 0o700;
}

/// Opaque platform-specific permission bits, for recording in a durable
/// fingerprint and comparing against a later observation of the same file.
/// Never interpret the result as mode bits; only compare it for equality.
pub fn toRawBits(permissions: Permissions) u64 {
    if (comptime is_windows) return @intFromEnum(permissions);
    return permissions.toMode();
}

test "confidentiality verification is advertised per platform" {
    try std.testing.expectEqual(builtin.os.tag != .windows, verifies_confidentiality);
}

test "private constants keep their POSIX mode bits" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), private_file.toMode());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), private_dir.toMode());
}

test "owner privacy predicate matches the mode test it replaced" {
    if (comptime is_windows) return error.SkipZigTest;
    for ([_]std.posix.mode_t{ 0o600, 0o700, 0o400, 0o000 }) |mode| {
        try std.testing.expect(isPrivateToOwner(.fromMode(mode)));
    }
    for ([_]std.posix.mode_t{ 0o640, 0o604, 0o666, 0o777, 0o601 }) |mode| {
        try std.testing.expect(!isPrivateToOwner(.fromMode(mode)));
    }
}

test "write predicates match the mode tests they replaced" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expect(isOwnerWritable(.fromMode(0o600)));
    try std.testing.expect(isOwnerWritable(.fromMode(0o200)));
    try std.testing.expect(!isOwnerWritable(.fromMode(0o400)));
    try std.testing.expect(!isOwnerWritable(.fromMode(0o077)));

    try std.testing.expect(isWritable(.fromMode(0o600)));
    try std.testing.expect(isWritable(.fromMode(0o002)));
    try std.testing.expect(isWritable(.fromMode(0o020)));
    try std.testing.expect(!isWritable(.fromMode(0o444)));
    try std.testing.expect(!isWritable(.fromMode(0o000)));
}

test "group and other write protection matches the mode test it replaced" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expect(isProtectedFromGroupAndOther(.fromMode(0o600)));
    try std.testing.expect(isProtectedFromGroupAndOther(.fromMode(0o644)));
    try std.testing.expect(!isProtectedFromGroupAndOther(.fromMode(0o620)));
    try std.testing.expect(!isProtectedFromGroupAndOther(.fromMode(0o602)));
    try std.testing.expect(!isProtectedFromGroupAndOther(.fromMode(0o666)));
}

test "exact private predicates accept only their own bits" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expect(isExactlyPrivateFile(.fromMode(0o600)));
    try std.testing.expect(!isExactlyPrivateFile(.fromMode(0o700)));
    try std.testing.expect(!isExactlyPrivateFile(.fromMode(0o640)));

    try std.testing.expect(isExactlyPrivateDir(.fromMode(0o700)));
    try std.testing.expect(!isExactlyPrivateDir(.fromMode(0o600)));
    try std.testing.expect(!isExactlyPrivateDir(.fromMode(0o750)));
}

test "exact private predicates ignore bits above the permission field" {
    if (comptime is_windows) return error.SkipZigTest;
    // Callers pass `stat.permissions`, which on POSIX can carry file-type and
    // setuid bits above `0o777`; the tests these replaced masked them off.
    try std.testing.expect(isExactlyPrivateFile(.fromMode(0o100600)));
    try std.testing.expect(isExactlyPrivateDir(.fromMode(0o040700)));
}

test "raw bits round-trip the POSIX mode for fingerprinting" {
    if (comptime is_windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u64, 0o100600), toRawBits(.fromMode(0o100600)));
}
