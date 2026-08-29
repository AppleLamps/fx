//! Focused test root for the Windows ConPTY session backend. The module root
//! must be `src/` because the terminal backend imports across directories.
//! Run with: `zig test src/windows_session_test.zig` (Windows hosts only; the
//! tests skip elsewhere).

test {
    _ = @import("core/terminal/windows_session.zig");
}
