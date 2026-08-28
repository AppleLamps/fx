//! Windows Job Object process-tree control.
//!
//! Windows has neither process groups nor signals, so the POSIX pattern this
//! codebase uses for command teardown — spawn into a new process group, then
//! `kill(-pgid, …)` to take down the whole tree — has no direct translation.
//! A Job Object is the equivalent containment primitive: a process assigned to
//! a job carries that membership to every descendant it creates, and
//! terminating the job terminates all of them at once.
//!
//! `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` additionally guarantees that dropping
//! the last handle to the job kills whatever is still inside it, so a crash in
//! the parent cannot strand a runaway descendant.
//!
//! **Known race.** `std.process.spawn` does not expose `CREATE_SUSPENDED`, so a
//! child is assigned to its job a moment *after* it starts running. A process
//! that forks a descendant inside that window and exits will leave that
//! descendant outside the job, exactly as an unassigned process would be. The
//! POSIX path has no equivalent gap, because `pgid` is applied by the spawn
//! itself. Closing this requires suspended-start support in the spawn layer.
//!
//! None of this can be exercised on a POSIX host. The tests below cover the
//! ABI layout of the structures passed to Win32, which is the part that is
//! checkable anywhere and the part most likely to be silently wrong.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Error = error{
    JobObjectUnavailable,
    JobAssignmentFailed,
    JobTerminationFailed,
};

/// `JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation`.
const job_object_extended_limit_information: c_int = 9;

/// Kill every process still in the job when its last handle closes.
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: windows.DWORD = 0x00002000;

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: windows.LARGE_INTEGER,
    PerJobUserTimeLimit: windows.LARGE_INTEGER,
    LimitFlags: windows.DWORD,
    MinimumWorkingSetSize: windows.SIZE_T,
    MaximumWorkingSetSize: windows.SIZE_T,
    ActiveProcessLimit: windows.DWORD,
    Affinity: windows.ULONG_PTR,
    PriorityClass: windows.DWORD,
    SchedulingClass: windows.DWORD,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: windows.SIZE_T,
    JobMemoryLimit: windows.SIZE_T,
    PeakProcessMemoryUsed: windows.SIZE_T,
    PeakJobMemoryUsed: windows.SIZE_T,
};

// The Job Object API is not declared in `std.os.windows` as of Zig 0.16.0.
extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn TerminateJobObject(
    hJob: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// A process-tree container. Not available off Windows; callers gate on
/// `supported` rather than handling a runtime error on POSIX.
pub const supported = builtin.os.tag == .windows;

pub const Job = struct {
    handle: windows.HANDLE,

    /// Creates a job that kills its remaining members when the last handle to
    /// it closes, so an abrupt exit cannot strand descendants.
    pub fn create() Error!Job {
        if (comptime !supported) return error.JobObjectUnavailable;

        const handle = CreateJobObjectW(null, null) orelse
            return error.JobObjectUnavailable;
        errdefer windows.CloseHandle(handle);

        var info = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // `windows.BOOL` is a non-exhaustive enum, not an integer: comparing
        // against 1 would be wrong because any nonzero value is truthy.
        if (!SetInformationJobObject(
            handle,
            job_object_extended_limit_information,
            &info,
            @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ).toBool()) {
            return error.JobObjectUnavailable;
        }

        return .{ .handle = handle };
    }

    /// Brings a process and its future descendants into the job. See the
    /// module comment for the spawn-to-assignment race.
    pub fn assign(self: Job, process: windows.HANDLE) Error!void {
        if (comptime !supported) return error.JobAssignmentFailed;
        if (!AssignProcessToJobObject(self.handle, process).toBool()) {
            return error.JobAssignmentFailed;
        }
    }

    /// Terminates every process in the job. This is the counterpart of
    /// `kill(-pgid, SIGKILL)`: immediate and not catchable, so callers wanting
    /// a graceful stop must attempt that before reaching for this.
    pub fn terminate(self: Job, exit_code: u32) Error!void {
        if (comptime !supported) return error.JobTerminationFailed;
        if (!TerminateJobObject(self.handle, exit_code).toBool()) {
            return error.JobTerminationFailed;
        }
    }

    pub fn close(self: Job) void {
        if (comptime !supported) return;
        windows.CloseHandle(self.handle);
    }
};

test "job object support is advertised per platform" {
    try std.testing.expectEqual(builtin.os.tag == .windows, supported);
}

test "creating a job off Windows reports unavailable rather than trapping" {
    if (comptime supported) return error.SkipZigTest;
    try std.testing.expectError(error.JobObjectUnavailable, Job.create());
}

test "extended limit information matches the documented x64 ABI" {
    // These structures cross the Win32 boundary by size, and
    // `SetInformationJobObject` rejects a wrong `cbJobObjectInformationLength`
    // rather than misbehaving quietly. Checking the layout is possible on any
    // 64-bit host, which is the only part of this module a POSIX CI run can
    // meaningfully verify.
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(IO_COUNTERS));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(JOBOBJECT_BASIC_LIMIT_INFORMATION));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
}

test "basic limit information places its fields at the documented offsets" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    const B = JOBOBJECT_BASIC_LIMIT_INFORMATION;
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(B, "PerProcessUserTimeLimit"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(B, "PerJobUserTimeLimit"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(B, "LimitFlags"));
    // 4 bytes of padding here: the working-set fields are pointer-aligned.
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(B, "MinimumWorkingSetSize"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(B, "MaximumWorkingSetSize"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(B, "ActiveProcessLimit"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(B, "Affinity"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(B, "PriorityClass"));
    try std.testing.expectEqual(@as(usize, 60), @offsetOf(B, "SchedulingClass"));
}

test "kill-on-close is the flag the job is created with" {
    // The whole point of the job is that dropping the last handle takes the
    // tree with it; a wrong constant would silently disable that.
    try std.testing.expectEqual(@as(windows.DWORD, 0x2000), JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE);
    try std.testing.expectEqual(@as(c_int, 9), job_object_extended_limit_information);
}
