//! Windows ConPTY session backend — the third arm of `native_session.Registry`.
//!
//! The POSIX backend is tmux-shaped: a host process owns sessions that outlive
//! fx, and clients reach them over a Unix socket. Windows has neither tmux nor
//! a working `std.Io.net` loopback (measured: connect and accept succeed but no
//! data flows; see `docs/windows-port-finalization.md`), so this backend is
//! deliberately **in-process**: sessions live inside the fx process and die
//! with it. Cross-invocation recovery stays out of scope, exactly as the phase
//! 4 report scoped it, and the honest consequence is `screen_recovery =
//! .unavailable` on every fact.
//!
//! What is real here, all measured by `src/pty_probe.zig` on a real host:
//!
//! - Sessions are ConPTY children spawned through `windows_pty.spawnAttached`,
//!   which creates the process suspended, assigns its Job Object, and only
//!   then resumes it. Containment is mandatory: a session's only teardown is
//!   its job.
//! - A reader thread drains the pty output pipe into a bounded ring of
//!   retained bytes with absolute offsets (segment 1). Reads older than the
//!   ring report a `raw_gap` rather than pretending the bytes are there.
//! - Pipe EOF arrives as `ReadFile` failing with `ERROR_BROKEN_PIPE`, never as
//!   a zero-byte read; the reader treats that as clean end of output.
//! - Teardown ordering follows the phase 2 deadlock lesson: terminate the Job
//!   Object first, then close the pseudoconsole (which ends conhost and closes
//!   the pipe write end, finishing the pending read), join the reader, and
//!   only then wait on the child.
//! - Screen rendering reuses the shared terminal engine (`Grid.feed` /
//!   `renderSnapshot`), so screen snapshots and `screen` facts come from the
//!   same VT model the POSIX backend's renderer uses.
//!
//! Deliberate v1 gaps, each returning a structured failure rather than a
//! silent no-op: monitor conditions `output_matches`, `tcp_ready`,
//! `http_ready`, and `custom_probe` are unsupported (no regex, and loopback
//! sockets are broken); `close` graceful and force both terminate the job,
//! because Windows console has no SIGHUP equivalent to deliver.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const windows_pty = @import("windows_pty.zig");
const terminal_engine = @import("engine.zig");
const session_layout = @import("../session/session_layout.zig");
const io_mod = @import("../shared/io.zig");

const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const supported = builtin.os.tag == .windows;

/// Matches the POSIX backend's session table size (`native_session.zig`).
pub const max_sessions: usize = 16;

/// Retained raw output. Reads older than the ring report a gap instead of
/// failing, so an idle-but-large session degrades reads rather than losing
/// the session.
const output_ring_bytes: usize = 2 * 1024 * 1024;
const max_monitors: usize = 16;
const max_events: usize = 128;
const wait_poll_ms: u32 = 25;
const default_columns: u16 = 80;
const default_rows: u16 = 24;

const Monitor = struct {
    id_buf: [16]u8,
    condition: contracts.MonitorCondition,
    notify: contracts.NotifySchedule,
    state: contracts.MonitorState = .active,

    fn id(self: *const Monitor) []const u8 {
        return &self.id_buf;
    }
};

const MonitorEventEntry = struct {
    event_id: u64,
    monitor_id_buf: [16]u8,
    reason: contracts.MonitorEventReason,
};

/// The subset of the start request's minted persistence that ownership checks
/// need. The holder proof is the secret; everything else is identity.
const Ownership = struct {
    proof: contracts.HolderProof,
    generation: u64,
    actor: contracts.ActorRole,
    durable_session_id: []u8,
    workspace_root: []u8,
    controls: contracts.AllowedControls,
};

/// One ConPTY session. All mutable state is guarded by `mutex`; the reader
/// thread and action dispatchers share it.
const Session = struct {
    alloc: Allocator,
    id: []u8,
    mutex: std.Io.Mutex = .init,
    pty: ?windows_pty.PseudoConsole = null,
    child: ?windows_pty.Child = null,
    reader: ?std.Thread = null,
    monitor: ?std.Thread = null,
    grid: ?terminal_engine.Grid = null,
    dimensions: contracts.Dimensions = .{
        .rows = default_rows,
        .columns = default_columns,
    },
    cwd: []u8 = "",
    command: ?[]u8 = null,
    shell_label: []u8 = "",
    lifecycle: contracts.Lifecycle = .starting,
    attention: contracts.AttentionState = .{},
    ownership: ?Ownership = null,
    controls: contracts.AllowedControls = .full(),

    /// Absolute offset of `ring[0]`. The segment is always 1; offsets grow
    /// monotonically and the ring retains the most recent `output_ring_bytes`
    /// bytes. Reads older than the ring report a `raw_gap`.
    ring: []u8 = &.{},
    ring_start_offset: u64 = 0,
    ring_len: usize = 0,
    total_output: u64 = 0,
    last_output_ms: i64 = 0,
    eof: bool = false,
    reader_failed: bool = false,
    console_closed: bool = false,
    /// Set by the monitor thread after the child process handle is signaled.
    /// ConPTY keeps conhost (and the output pipe) alive while the HPCON is
    /// open even after the child exits, so child exit and pipe EOF are
    /// independent events and child exit is the authoritative exit signal.
    child_done: bool = false,
    exit_code: ?u32 = null,
    wait_cancelled: bool = false,
    monitors: std.ArrayList(Monitor) = .empty,
    events: std.ArrayList(MonitorEventEntry) = .empty,
    next_event_id: u64 = 1,
    next_monitor_counter: u64 = 0,
    closed: bool = false,

    fn outputCursor(self: *const Session) contracts.RawCursor {
        return .{ .segment = 1, .offset = self.total_output };
    }

    fn facts(self: *Session) contracts.SessionFacts {
        return .{
            .session_id = self.id,
            .lifecycle = self.lifecycle,
            .attention = self.attention,
            .backend = .native,
            .persistence = .durable,
            .output_cursor = self.outputCursor(),
            .screen_recovery = .{ .unavailable = .missing },
            .active_monitor_count = @intCast(self.monitors.items.len),
            .next_actions = self.controls,
        };
    }

    /// Appends reader output to the ring and the engine grid. Once the ring is
    /// full the oldest half is dropped, so a burst of output degrades old
    /// reads into gaps instead of shedding one byte at a time.
    fn appendOutput(self: *Session, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (self.grid) |*grid| grid.feed(bytes) catch {};
        self.last_output_ms = io_mod.milliTimestamp();
        var rest = bytes;
        while (true) {
            const space = self.ring.len - self.ring_len;
            if (rest.len > space) {
                const drop = self.ring.len / 2;
                self.ring_start_offset += drop;
                self.ring_len -= drop;
                continue;
            }
            var offset: usize = 0;
            while (offset < rest.len) {
                const write_at: usize = @intCast(
                    (self.ring_start_offset + self.ring_len) % self.ring.len,
                );
                const first = @min(rest.len - offset, self.ring.len - write_at);
                @memcpy(self.ring[write_at .. write_at + first], rest[offset .. offset + first]);
                self.ring_len += first;
                offset += first;
            }
            self.total_output += rest.len;
            return;
        }
    }

    /// Copies retained output starting at `from_offset` into `out`.
    /// Returns how many bytes were copied; callers report gaps themselves.
    fn copyRetained(self: *Session, from_offset: u64, out: []u8) usize {
        if (self.total_output <= from_offset) return 0;
        const begin = @max(from_offset, self.ring_start_offset);
        const available: usize = @intCast(self.total_output - begin);
        const length = @min(available, out.len);
        var index: usize = @intCast(begin - self.ring_start_offset);
        var copied: usize = 0;
        while (copied < length) {
            const run = @min(length - copied, self.ring.len - index);
            @memcpy(out[copied .. copied + run], self.ring[index .. index + run]);
            copied += run;
            index = (index + run) % self.ring.len;
        }
        return copied;
    }

    fn hasGap(self: *Session, from_offset: u64) bool {
        return from_offset < self.ring_start_offset;
    }
};

fn formatMonitorId(buffer: *[16]u8, counter: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "mon-{d:0>11}", .{counter % 100_000_000_000}) catch unreachable;
}

pub const Registry = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    sessions: [max_sessions]?*Session = @splat(null),
    counter: u64 = 0,

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc };
    }

    /// Terminates every session's process tree. Sessions become `.closed`
    /// but stay listed until `deinit`, matching the POSIX host's shutdown
    /// contract of killing children without destroying the listing.
    pub fn shutdownSessionsOnly(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (&self.sessions) |*slot| {
            if (slot.*) |session| self.terminateSessionLocked(session);
        }
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        for (&self.sessions) |*slot| {
            if (slot.*) |session| {
                self.terminateSessionLocked(session);
                self.destroySessionLocked(session);
            }
            slot.* = null;
        }
        // Unlock before invalidating self: a deferred unlock would swap on
        // already-poisoned mutex state.
        self.mutex.unlock(io_mod.getIo());
        self.* = undefined;
    }

    pub fn executeAuthorized(
        self: *Registry,
        request: contracts.ActionRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        if (comptime !supported) {
            return self.failure(.unsupported_host, request.action(), null);
        }
        return switch (request) {
            .start => |value| startAction(self, value, cancelled),
            .read => |value| readAction(self, value),
            .screen => |value| screenAction(self, value),
            .write => |value| writeAction(self, value),
            .wait => |value| waitAction(self, value, cancelled),
            .monitor => |value| monitorAction(self, value),
            .inspect => |value| inspectAction(self, value),
            .list => |value| listAction(self, value),
            .resize => |value| resizeAction(self, value),
            .signal => |value| signalAction(self, value),
            .close => |value| closeAction(self, value),
        };
    }

    pub fn cancelAuthorized(
        self: *Registry,
        session_id: []const u8,
        _: contracts.AuthorityClaim,
    ) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.findLocked(session_id)) |session| {
            session.wait_cancelled = true;
        }
    }

    fn failure(
        self: *Registry,
        code: contracts.StructuredErrorCode,
        action: contracts.Action,
        session_id: ?[]const u8,
    ) Allocator.Error!contracts.OwnedResult {
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .failure = .{ .action = action, .code = code, .session_id = session_id } },
        ) catch return error.OutOfMemory;
    }

    fn success(
        self: *Registry,
        result: contracts.Result,
    ) Allocator.Error!contracts.OwnedResult {
        return contracts.OwnedResult.init(self.alloc, result) catch return error.OutOfMemory;
    }

    fn findLocked(self: *Registry, session_id: []const u8) ?*Session {
        for (&self.sessions) |*slot| {
            const session = slot.* orelse continue;
            if (std.mem.eql(u8, session.id, session_id)) return session;
        }
        return null;
    }

    /// Verifies the caller's claim against the authority minted at start.
    /// The proof is the secret: byte equality with the stored holder proof is
    /// what makes every other check here meaningful.
    fn authorityAllowed(
        session: *Session,
        claim: ?contracts.AuthorityClaim,
        action: contracts.Action,
    ) bool {
        const owned_grant = session.ownership orelse return false;
        const presented = claim orelse return false;
        if (!std.mem.eql(u8, owned_grant.proof.bytes[0..], presented.proof.bytes[0..])) return false;
        if (presented.generation.value != owned_grant.generation) return false;
        if (!std.mem.eql(
            u8,
            owned_grant.durable_session_id,
            presented.principal.durable_session_id,
        )) return false;
        if (presented.actor != owned_grant.actor) return false;
        return session.controls.allows(action);
    }

    /// Phase 2 deadlock ordering: terminate the job, then close the
    /// pseudoconsole so conhost exits and the pending read finishes; join the
    /// reader without holding the session mutex; only then wait on the child.
    /// The registry mutex is already held.
    fn terminateSessionLocked(_: *Registry, session: *Session) void {
        session.mutex.lockUncancelable(io_mod.getIo());
        if (session.child) |child| child.terminate(1);
        if (session.pty != null and !session.console_closed) {
            session.pty.?.procs.close(session.pty.?.handle);
            session.console_closed = true;
        }
        session.mutex.unlock(io_mod.getIo());

        if (session.reader) |reader| {
            reader.join();
            session.mutex.lockUncancelable(io_mod.getIo());
            session.reader = null;
            session.mutex.unlock(io_mod.getIo());
        }
        if (session.monitor) |monitor| {
            monitor.join();
            session.mutex.lockUncancelable(io_mod.getIo());
            session.monitor = null;
            session.mutex.unlock(io_mod.getIo());
        }

        session.mutex.lockUncancelable(io_mod.getIo());
        defer session.mutex.unlock(io_mod.getIo());
        if (session.pty) |*pty| {
            if (!session.console_closed) {
                pty.procs.close(pty.handle);
                session.console_closed = true;
            }
            windows.CloseHandle(pty.input);
            windows.CloseHandle(pty.output);
            pty.* = undefined;
            session.pty = null;
        }
        if (session.child) |child| {
            _ = WaitForSingleObject(child.process, 10_000);
            session.exit_code = exitCodeOf(child.process);
            var mutable_child = child;
            mutable_child.close();
            session.child = null;
        }
        if (session.lifecycle != .closed) {
            session.lifecycle = contracts.transition_lifecycle(
                session.lifecycle,
                .close,
            ) catch session.lifecycle;
        }
        session.closed = true;
    }

    fn destroySessionLocked(self: *Registry, session: *Session) void {
        const alloc = self.alloc;
        if (session.grid) |*grid| grid.deinit();
        alloc.free(session.id);
        alloc.free(session.cwd);
        if (session.command) |command| alloc.free(command);
        alloc.free(session.shell_label);
        if (session.ownership) |*ownership| {
            alloc.free(ownership.durable_session_id);
            alloc.free(ownership.workspace_root);
        }
        alloc.free(session.ring);
        session.monitors.deinit(alloc);
        session.events.deinit(alloc);
        alloc.destroy(session);
    }
};

extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: u32,
) callconv(.winapi) u32;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *u32,
) callconv(.winapi) windows.BOOL;

fn exitCodeOf(process: windows.HANDLE) u32 {
    var code: u32 = 0;
    _ = GetExitCodeProcess(process, &code);
    return code;
}

const wait_object_0: u32 = 0;

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

extern "kernel32" fn SearchPathW(
    lpPath: ?[*:0]const u16,
    lpFileName: [*:0]const u16,
    lpExtension: ?[*:0]const u16,
    nBufferLength: u32,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*]u16,
) callconv(.winapi) u32;

fn writeToPty(handle: windows.HANDLE, bytes: []const u8) bool {
    var written: u32 = 0;
    return WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null).toBool();
}

/// ConPTY pipe EOF is `ReadFile` failing (broken pipe when conhost closes),
/// never a clean zero-byte read, so every reader failure here is end of
/// output. See `docs/windows-port-finalization.md`, probe 1.
/// Drains pseudoconsole output until the pipe breaks. EOF here means conhost
/// is gone, which happens when the pseudoconsole is closed (teardown or the
/// monitor thread after child exit), never merely because the child exited.
fn readerMain(session: *Session) void {
    const output = session.pty.?.output;
    var buffer: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        const ok = ReadFile(output, &buffer, buffer.len, &n, null);
        session.mutex.lockUncancelable(io_mod.getIo());
        defer session.mutex.unlock(io_mod.getIo());
        if (!ok.toBool() or n == 0) {
            session.eof = true;
            break;
        }
        session.appendOutput(buffer[0..n]);
        evaluateMonitorsLocked(session);
    }
}

/// Waits for the child to exit, records the exit code, and closes the
/// pseudoconsole so conhost releases the output pipe and the reader observes
/// EOF. Without this close the pipe stays open indefinitely on ConPTY.
fn monitorMain(session: *Session) void {
    const child = session.child.?;
    _ = WaitForSingleObject(child.process, std.time.ms_per_min * 60);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());
    session.exit_code = exitCodeOf(child.process);
    session.child_done = true;
    if (session.pty != null and !session.console_closed) {
        session.pty.?.procs.close(session.pty.?.handle);
        session.console_closed = true;
    }
    session.lifecycle = contracts.transition_lifecycle(
        session.lifecycle,
        .child_exited,
    ) catch session.lifecycle;
    evaluateMonitorsLocked(session);
}

fn monitorSupported(condition: contracts.MonitorCondition) bool {
    return switch (condition) {
        .process_exit, .exit_code, .output_contains, .output_quiet_ms, .path_exists => true,
        // No regex engine, and measured loopback sockets carry no data on
        // Windows, so these conditions cannot be honored honestly yet.
        .output_matches, .signal, .screen_matches, .tcp_ready, .http_ready, .custom_probe, .path_changed, .path_size => false,
    };
}

/// Evaluates active monitors against current session state. The session
/// mutex is held. Matched one-shot monitors become `.matched`; every state
/// change appends a bounded event.
fn evaluateMonitorsLocked(session: *Session) void {
    for (session.monitors.items) |*monitor| {
        if (monitor.state != .active) continue;
        const matched: bool = switch (monitor.condition) {
            .process_exit => session.eof or session.child_done,
            .exit_code => |code| session.eof and
                (session.exit_code orelse 0) == @as(u32, @bitCast(code)),
            .output_contains => |needle| blk: {
                // Search only the retained ring, newest first is not needed;
                // a contained substring anywhere in retained output matches.
                var search = RingSearch{ .session = session };
                break :blk search.contains(needle);
            },
            .output_quiet_ms => |quiet_ms| session.total_output > 0 and
                io_mod.milliTimestamp() - session.last_output_ms >= quiet_ms,
            .path_exists => |path| pathExists(path),
            else => false,
        };
        if (!matched) continue;
        monitor.state = .matched;
        appendEventLocked(session, monitor, .matched);
    }
}

fn appendEventLocked(
    session: *Session,
    monitor: *const Monitor,
    reason: contracts.MonitorEventReason,
) void {
    var entry = MonitorEventEntry{
        .event_id = session.next_event_id,
        .monitor_id_buf = monitor.id_buf,
        .reason = reason,
    };
    _ = &entry;
    session.next_event_id += 1;
    session.events.append(session.alloc, entry) catch {
        // Bounded log: dropping the oldest event keeps the budget.
        if (session.events.items.len > 0) {
            _ = session.events.orderedRemove(0);
            session.events.append(session.alloc, entry) catch {};
        }
    };
    if (session.events.items.len > max_events) {
        _ = session.events.orderedRemove(0);
    }
}

/// Substring search over the retained ring without copying it.
const RingSearch = struct {
    session: *Session,

    fn contains(self: RingSearch, needle: []const u8) bool {
        if (needle.len == 0 or needle.len > self.session.ring_len) return false;
        const start: usize = @intCast(self.session.ring_start_offset % self.session.ring.len);
        const retained: usize = @intCast(self.session.ring_len);
        var logical: usize = 0;
        while (logical + needle.len <= retained) : (logical += 1) {
            var matched = true;
            var offset: usize = 0;
            while (offset < needle.len) : (offset += 1) {
                const ring_index = (start + logical + offset) % self.session.ring.len;
                if (self.session.ring[ring_index] != needle[offset]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
};

fn pathExists(path: []const u8) bool {
    const alloc = std.heap.page_allocator;
    const resolved = io_mod.realpathAlloc(alloc, path) catch return false;
    alloc.free(resolved);
    return true;
}

fn findOnPath(comptime name: []const u8) bool {
    const name_w = std.unicode.utf8ToUtf16LeStringLiteral(name);
    var buffer: [1024]u16 = undefined;
    return SearchPathW(null, name_w, null, buffer.len, &buffer, null) > 0;
}

const ResolvedShell = struct {
    argv: [8][]const u8 = undefined,
    argv_len: usize = 0,
    label: []const u8 = "",

    fn args(self: *const ResolvedShell) []const []const u8 {
        return self.argv[0..self.argv_len];
    }
};

/// Resolves the login shell or requested executable into `CreateProcessW`
/// argv. The user-login default prefers PowerShell 7 and falls back to
/// Windows PowerShell 5.1; both are interactive shells, and a start command
/// is written into the shell rather than executed with `-Command`, matching
/// the POSIX backend's send-into-session semantics.
fn resolveShellArgv(spec: contracts.ShellSpec) !ResolvedShell {
    var resolved = ResolvedShell{};
    switch (spec) {
        .user_login => {
            if (findOnPath("pwsh.exe")) {
                resolved.argv[0] = "pwsh.exe";
                resolved.argv[1] = "-NoLogo";
                resolved.argv_len = 2;
                resolved.label = "pwsh";
            } else if (findOnPath("powershell.exe")) {
                resolved.argv[0] = "powershell.exe";
                resolved.argv[1] = "-NoLogo";
                resolved.argv_len = 2;
                resolved.label = "powershell";
            } else {
                return error.ShellUnavailable;
            }
        },
        .executable => |exe| {
            const path = exe.path;
            resolved.argv[0] = path;
            resolved.argv_len = 1;
            const basename_start = for (path, 0..) |c, i| {
                if (c == '\\' or c == '/') break i;
            } else 0;
            const basename = path[basename_start..];
            const is_powershell = containsCaseInsensitive(basename, "powershell") or
                containsCaseInsensitive(basename, "pwsh");
            if (is_powershell) {
                resolved.argv[resolved.argv_len] = "-NoLogo";
                resolved.argv_len += 1;
                if (exe.clean_start) {
                    resolved.argv[resolved.argv_len] = "-NoProfile";
                    resolved.argv_len += 1;
                }
            }
            resolved.label = path;
        },
    }
    return resolved;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var matched = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

/// Polls a return condition against session state. The session mutex is
/// taken per poll and released before sleeping, so the reader thread and
/// cancellation always make progress.
fn awaitCondition(
    session: *Session,
    condition: contracts.ReturnCondition,
    ceiling_ms: ?u64,
    cancelled: *const std.atomic.Value(bool),
) contracts.ReturnOutcome {
    const deadline = io_mod.milliTimestamp() + @as(i64, @intCast(ceiling_ms orelse std.math.maxInt(u32)));
    while (true) {
        if (cancelled.load(.seq_cst)) return .cancelled;
        if (session.wait_cancelled) return .cancelled;
        {
            session.mutex.lockUncancelable(io_mod.getIo());
            defer session.mutex.unlock(io_mod.getIo());
            const done: ?contracts.ReturnOutcome = switch (condition) {
                .started => if (session.lifecycle == .running) .started else null,
                .exit => if (session.child_done)
                    .{ .exited = @intCast(session.exit_code orelse 0) }
                else if (session.eof)
                    // Pipe EOF without a monitor observation (conhost died or
                    // console closed externally); treat as an exit with an
                    // unknown code, matching the POSIX EOF semantics.
                    .{ .exited = @intCast(session.exit_code orelse 0) }
                else
                    null,
                .quiet => |quiet_ms| if (io_mod.milliTimestamp() - session.last_output_ms >= quiet_ms)
                    .condition_met
                else
                    null,
                .match => |needle| if ((RingSearch{ .session = session }).contains(needle))
                    .condition_met
                else
                    null,
            };
            if (done) |outcome| return outcome;
        }
        if (io_mod.milliTimestamp() >= deadline) return .safety_ceiling;
        io_mod.sleep(wait_poll_ms * std.time.ns_per_ms);
    }
}

fn lookupSession(
    self: *Registry,
    session_id: []const u8,
    claim: ?contracts.AuthorityClaim,
    action: contracts.Action,
) ?*Session {
    self.mutex.lockUncancelable(io_mod.getIo());
    defer self.mutex.unlock(io_mod.getIo());
    const session = self.findLocked(session_id) orelse return null;
    if (!Registry.authorityAllowed(session, claim, action)) return null;
    return session;
}

fn sessionNotFound(
    self: *Registry,
    action: contracts.Action,
    session_id: []const u8,
) Allocator.Error!contracts.OwnedResult {
    // Ownership failure and missing session are deliberately
    // indistinguishable to a caller that does not hold the proof.
    return self.failure(.session_not_found, action, session_id);
}

fn startAction(
    self: *Registry,
    request: contracts.StartRequest,
    cancelled: *const std.atomic.Value(bool),
) Allocator.Error!contracts.OwnedResult {
    const alloc = self.alloc;
    const persistence = request.persistence orelse
        return self.failure(.authority_denied, .start, null);

    const session = alloc.create(Session) catch return error.OutOfMemory;
    var session_opt: ?*Session = session;
    errdefer if (session_opt) |value| alloc.destroy(value);
    var session_id = session_layout.generateSessionId(alloc) catch return error.OutOfMemory;
    errdefer alloc.free(session_id);
    var ring = alloc.alloc(u8, output_ring_bytes) catch return error.OutOfMemory;
    errdefer alloc.free(ring);
    var cwd = alloc.dupe(u8, request.cwd) catch return error.OutOfMemory;
    errdefer alloc.free(cwd);
    var command: ?[]u8 = if (request.command) |value|
        (alloc.dupe(u8, value) catch return error.OutOfMemory)
    else
        null;
    errdefer if (command) |value| alloc.free(value);
    var durable_id = alloc.dupe(
        u8,
        persistence.grant.principal.durable_session_id,
    ) catch return error.OutOfMemory;
    errdefer alloc.free(durable_id);
    var shell_label = alloc.dupe(u8, "user shell") catch return error.OutOfMemory;
    errdefer alloc.free(shell_label);
    var workspace_root = alloc.dupe(
        u8,
        persistence.grant.principal.workspace_root,
    ) catch return error.OutOfMemory;
    errdefer alloc.free(workspace_root);

    const dimensions = request.dimensions orelse contracts.Dimensions{
        .rows = default_rows,
        .columns = default_columns,
    };
    var grid_opt: ?terminal_engine.Grid = terminal_engine.Grid.init(
        alloc,
        dimensions.columns,
        dimensions.rows,
    ) catch return error.OutOfMemory;
    errdefer if (grid_opt) |*value| value.deinit();

    var pty = windows_pty.PseudoConsole.create(.{
        .columns = dimensions.columns,
        .rows = dimensions.rows,
    }) catch return self.failure(.pty_unavailable, .start, null);

    const resolved = resolveShellArgv(request.shell) catch {
        pty.procs.close(pty.handle);
        windows.CloseHandle(pty.input);
        windows.CloseHandle(pty.output);
        return self.failure(.shell_unavailable, .start, null);
    };

    const child = windows_pty.spawnAttached(alloc, pty, resolved.args(), request.cwd) catch {
        pty.procs.close(pty.handle);
        windows.CloseHandle(pty.input);
        windows.CloseHandle(pty.output);
        return self.failure(.startup_failed, .start, null);
    };

    session.* = .{
        .alloc = alloc,
        .id = session_id,
        .ring = ring,
        .grid = grid_opt.?,
        .dimensions = dimensions,
        .pty = pty,
        .child = child,
        .cwd = cwd,
        .command = command,
        .shell_label = shell_label,
        .last_output_ms = io_mod.milliTimestamp(),
        .ownership = .{
            .proof = persistence.proof,
            .generation = persistence.grant.generation.value,
            .actor = persistence.grant.actor,
            .durable_session_id = durable_id,
            .workspace_root = workspace_root,
            .controls = persistence.grant.controls,
        },
        .controls = persistence.grant.controls,
    };
    // Ownership of every allocation, the grid, the pty, and the child has
    // moved into `session`. Neutralize the construction errdefers so later
    // failures clean up through `destroySessionLocked` instead of freeing
    // twice.
    session_opt = null;
    grid_opt = null;
    session_id = "";
    ring = &.{};
    cwd = "";
    command = null;
    durable_id = "";
    shell_label = "";
    workspace_root = "";
    session.lifecycle = contracts.transition_lifecycle(
        .starting,
        .child_started,
    ) catch .starting;

    // The reader takes ownership of draining the pty from here.
    const reader = std.Thread.spawn(.{}, readerMain, .{session}) catch {
        self.terminateSessionLocked(session);
        self.destroySessionLocked(session);
        return self.failure(.startup_failed, .start, null);
    };
    session.reader = reader;

    // The monitor thread turns child exit into pipe EOF by closing the
    // pseudoconsole; see monitorMain.
    const monitor = std.Thread.spawn(.{}, monitorMain, .{session}) catch {
        self.terminateSessionLocked(session);
        self.destroySessionLocked(session);
        return self.failure(.startup_failed, .start, null);
    };
    session.monitor = monitor;

    // A start command is written into the interactive shell, matching the
    // POSIX backend's send-into-session semantics.
    if (request.command) |value| {
        _ = writeToPty(pty.input, value);
        _ = writeToPty(pty.input, "\r\n");
    }

    {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var slot_index: ?usize = null;
        for (&self.sessions, 0..) |*slot, index| {
            if (slot.* == null) {
                slot.* = session;
                slot_index = index;
                break;
            }
        }
        if (slot_index == null) {
            self.terminateSessionLocked(session);
            self.destroySessionLocked(session);
            return self.failure(.capacity_exceeded, .start, null);
        }
    }

    var outcome: contracts.ReturnOutcome = .started;
    if (request.return_when) |condition| {
        outcome = awaitCondition(session, condition, request.wait_ceiling_ms, cancelled);
    }

    {
        session.mutex.lockUncancelable(io_mod.getIo());
        defer session.mutex.unlock(io_mod.getIo());
        return self.success(.{ .success = .{ .start = .{
            .session = session.facts(),
            .outcome = outcome,
        } } });
    }
}

const max_read_bytes: usize = 256 * 1024;
const max_encoded_write_bytes: usize = contracts.max_write_bytes * 2;

fn readAction(
    self: *Registry,
    request: contracts.ReadRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .read) orelse
        return sessionNotFound(self, .read, request.session_id);
    if (request.cursor.segment != 1) {
        return self.failure(.cursor_gap, .read, request.session_id);
    }
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());

    const gap = session.hasGap(request.cursor.offset);
    const from = @max(request.cursor.offset, session.ring_start_offset);
    var output: []u8 = &.{};
    if (!gap) {
        const available: usize = @intCast(session.total_output - from);
        const capacity = @min(available, max_read_bytes);
        if (capacity > 0) {
            const buffer = self.alloc.alloc(u8, capacity) catch return error.OutOfMemory;
            const length = session.copyRetained(from, buffer);
            output = buffer[0..length];
        }
    }
    defer if (output.len > 0) self.alloc.free(output.ptr[0..output.len]);

    var facts = session.facts();
    if (gap) {
        facts.raw_gap = .{
            .missing_from = request.cursor,
            .available_from = .{ .segment = 1, .offset = session.ring_start_offset },
        };
    }
    return self.success(.{ .success = .{ .read = .{
        .session = facts,
        .output = output,
        .raw_range = if (output.len > 0) .{
            .start = .{ .segment = 1, .offset = from },
            .end = .{ .segment = 1, .offset = from + output.len },
        } else null,
    } } });
}

fn screenAction(
    self: *Registry,
    request: contracts.SessionRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .screen) orelse
        return sessionNotFound(self, .screen, request.session_id);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());
    const grid = &(session.grid orelse
        return self.failure(.screen_unavailable, .screen, request.session_id));
    var snapshot = grid.renderSnapshot(self.alloc) catch
        return self.failure(.screen_unavailable, .screen, request.session_id);
    defer snapshot.deinit(self.alloc);
    return self.success(.{ .success = .{ .screen = .{
        .session = session.facts(),
        .snapshot = snapshot.view(),
    } } });
}

fn keySequence(key: contracts.NamedKey) []const u8 {
    return switch (key) {
        .enter => "\r",
        .tab => "\t",
        .escape => "\x1b",
        .backspace => "\x7f",
        .delete => "\x1b[3~",
        .insert => "\x1b[2~",
        .arrow_up => "\x1b[A",
        .arrow_down => "\x1b[B",
        .arrow_right => "\x1b[C",
        .arrow_left => "\x1b[D",
        .home => "\x1b[H",
        .end => "\x1b[F",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
    };
}

fn controlByte(control: contracts.ControlInput) u8 {
    if (control.character == '?') return 0x1f;
    return control.character - '@';
}

fn writeAction(
    self: *Registry,
    request: contracts.WriteRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .write) orelse
        return sessionNotFound(self, .write, request.session_id);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());

    const actor = if (request.authority) |claim| claim.actor else .agent;
    switch (request.lease) {
        .acquire => {
            const want: contracts.WriteLease =
                if (actor == .human) .human else .agent;
            if (session.attention.write_lease != .none and
                session.attention.write_lease != want)
            {
                return self.failure(.lease_conflict, .write, request.session_id);
            }
            session.attention.write_lease = want;
        },
        .release, .revoke => session.attention.write_lease = .none,
        .use => {},
    }
    session.attention.validate() catch
        return self.failure(.lease_conflict, .write, request.session_id);

    const payload = request.payload orelse {
        return self.success(.{ .success = .{ .write = .{
            .session = session.facts(),
            .accepted_bytes = 0,
        } } });
    };

    const pty = &(session.pty orelse
        return self.failure(.session_lost, .write, request.session_id));

    const encoded = self.alloc.alloc(u8, max_encoded_write_bytes) catch
        return error.OutOfMemory;
    defer self.alloc.free(encoded);
    var length: usize = 0;
    switch (payload) {
        .text, .paste => |bytes| {
            @memcpy(encoded[0..bytes.len], bytes);
            length = bytes.len;
        },
        .keys => |keys| {
            for (keys) |key| {
                const sequence = keySequence(key);
                @memcpy(encoded[length .. length + sequence.len], sequence);
                length += sequence.len;
            }
        },
        .controls => |controls| {
            for (controls) |control| {
                encoded[length] = controlByte(control);
                length += 1;
            }
        },
    }

    if (!writeToPty(pty.input, encoded[0..length])) {
        return self.failure(.session_lost, .write, request.session_id);
    }
    return self.success(.{ .success = .{ .write = .{
        .session = session.facts(),
        .accepted_bytes = @intCast(length),
    } } });
}

fn waitAction(
    self: *Registry,
    request: contracts.WaitRequest,
    cancelled: *const std.atomic.Value(bool),
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .wait) orelse
        return sessionNotFound(self, .wait, request.session_id);
    const outcome = awaitCondition(
        session,
        request.return_when,
        request.safety_ceiling_ms,
        cancelled,
    );
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());
    return self.success(.{ .success = .{ .wait = .{
        .session = session.facts(),
        .outcome = outcome,
    } } });
}

fn monitorAction(
    self: *Registry,
    request: contracts.MonitorRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .monitor) orelse
        return sessionNotFound(self, .monitor, request.session_id);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());

    switch (request.operation) {
        .add => |definition| {
            if (!monitorSupported(definition.condition)) {
                return self.failure(.monitor_unavailable, .monitor, request.session_id);
            }
            if (session.monitors.items.len >= max_monitors) {
                return self.failure(.capacity_exceeded, .monitor, request.session_id);
            }
            var monitor = Monitor{
                .id_buf = undefined,
                .condition = definition.condition,
                .notify = definition.notify_schedule,
            };
            _ = formatMonitorId(&monitor.id_buf, session.next_monitor_counter);
            session.next_monitor_counter += 1;
            session.monitors.append(session.alloc, monitor) catch
                return error.OutOfMemory;
            const added = &session.monitors.items[session.monitors.items.len - 1];
            // An already-satisfied condition matches immediately.
            evaluateMonitorsLocked(session);
            return self.success(.{ .success = .{ .monitor = .{
                .session = session.facts(),
                .monitor_id = self.alloc.dupe(u8, added.id()) catch
                    return error.OutOfMemory,
            } } });
        },
        .update => |value| {
            if (!monitorSupported(value.definition.condition)) {
                return self.failure(.monitor_unavailable, .monitor, request.session_id);
            }
            for (session.monitors.items) |*monitor| {
                if (!std.mem.eql(u8, monitor.id(), value.monitor_id)) continue;
                monitor.condition = value.definition.condition;
                monitor.notify = value.definition.notify_schedule;
                monitor.state = .active;
                return self.success(.{ .success = .{ .monitor = .{
                    .session = session.facts(),
                    .monitor_id = self.alloc.dupe(u8, monitor.id()) catch
                        return error.OutOfMemory,
                } } });
            }
            return self.failure(.monitor_unavailable, .monitor, request.session_id);
        },
        .pause => |monitor_id| {
            for (session.monitors.items) |*monitor| {
                if (!std.mem.eql(u8, monitor.id(), monitor_id)) continue;
                monitor.state = .paused;
                appendEventLocked(session, monitor, .paused);
                return self.success(.{ .success = .{ .monitor = .{
                    .session = session.facts(),
                    .monitor_id = self.alloc.dupe(u8, monitor.id()) catch
                        return error.OutOfMemory,
                } } });
            }
            return self.failure(.monitor_unavailable, .monitor, request.session_id);
        },
        .@"resume" => |monitor_id| {
            for (session.monitors.items) |*monitor| {
                if (!std.mem.eql(u8, monitor.id(), monitor_id)) continue;
                monitor.state = .active;
                appendEventLocked(session, monitor, .resumed);
                return self.success(.{ .success = .{ .monitor = .{
                    .session = session.facts(),
                    .monitor_id = self.alloc.dupe(u8, monitor.id()) catch
                        return error.OutOfMemory,
                } } });
            }
            return self.failure(.monitor_unavailable, .monitor, request.session_id);
        },
        .remove => |monitor_id| {
            for (session.monitors.items, 0..) |*monitor, index| {
                if (!std.mem.eql(u8, monitor.id(), monitor_id)) continue;
                appendEventLocked(session, monitor, .removed);
                _ = session.monitors.orderedRemove(index);
                return self.success(.{ .success = .{ .monitor = .{
                    .session = session.facts(),
                } } });
            }
            return self.failure(.monitor_unavailable, .monitor, request.session_id);
        },
    }
}

fn inspectAction(
    self: *Registry,
    request: contracts.SessionRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .inspect) orelse
        return sessionNotFound(self, .inspect, request.session_id);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());

    const monitors = self.alloc.alloc(contracts.MonitorSummary, session.monitors.items.len) catch
        return error.OutOfMemory;
    defer self.alloc.free(monitors);
    for (session.monitors.items, 0..) |*monitor, index| {
        monitors[index] = .{ .monitor_id = monitor.id(), .state = monitor.state };
    }
    const event_count = @min(session.events.items.len, request.max_events);
    const events = self.alloc.alloc(contracts.MonitorEvent, event_count) catch
        return error.OutOfMemory;
    defer self.alloc.free(events);
    const skip = session.events.items.len - event_count;
    for (session.events.items[skip..], 0..) |entry, index| {
        events[index] = .{
            .event_id = entry.event_id,
            .monitor_id = entry.monitor_id_buf[0..],
            .reason = entry.reason,
            .lifecycle = session.lifecycle,
            .cursor = session.outputCursor(),
            .created_at_ms = session.last_output_ms,
        };
    }
    return self.success(.{ .success = .{ .inspect = .{
        .session = session.facts(),
        .shell = session.shell_label,
        .cwd = session.cwd,
        .command = session.command,
        .monitors = monitors,
        .events = events,
        .next_event_id = session.next_event_id,
    } } });
}

fn listAction(
    self: *Registry,
    filters: contracts.ListFilters,
) Allocator.Error!contracts.OwnedResult {
    self.mutex.lockUncancelable(io_mod.getIo());
    defer self.mutex.unlock(io_mod.getIo());
    var listed: usize = 0;
    for (&self.sessions) |*slot| {
        const session = slot.* orelse continue;
        if (filters.lifecycle) |lifecycle| {
            if (session.lifecycle != lifecycle) continue;
        }
        if (filters.backend) |backend| {
            if (backend != .native) continue;
        }
        if (filters.workspace_root) |root| {
            const ownership = session.ownership orelse continue;
            if (!std.mem.eql(u8, ownership.workspace_root, root)) continue;
        }
        listed += 1;
    }
    const sessions = self.alloc.alloc(contracts.SessionFacts, listed) catch
        return error.OutOfMemory;
    var index: usize = 0;
    for (&self.sessions) |*slot| {
        const session = slot.* orelse continue;
        if (filters.lifecycle) |lifecycle| {
            if (session.lifecycle != lifecycle) continue;
        }
        if (filters.backend) |backend| {
            if (backend != .native) continue;
        }
        if (filters.workspace_root) |root| {
            const ownership = session.ownership orelse continue;
            if (!std.mem.eql(u8, ownership.workspace_root, root)) continue;
        }
        sessions[index] = session.facts();
        index += 1;
    }
    // success() clones the facts into the owned result; this temporary slice
    // (and any per-session slices that back it) is not needed after that.
    const result = self.success(.{ .success = .{ .list = .{ .sessions = sessions } } });
    self.alloc.free(sessions);
    return result;
}

fn resizeAction(
    self: *Registry,
    request: contracts.ResizeRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .resize) orelse
        return sessionNotFound(self, .resize, request.session_id);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());
    const pty = &(session.pty orelse
        return self.failure(.session_lost, .resize, request.session_id));
    pty.resize(.{
        .columns = request.dimensions.columns,
        .rows = request.dimensions.rows,
    }) catch return self.failure(.session_lost, .resize, request.session_id);
    if (session.grid) |*grid| {
        grid.resize(request.dimensions.columns, request.dimensions.rows) catch {};
    }
    session.dimensions = request.dimensions;
    return self.success(.{ .success = .{ .resize = .{
        .session = session.facts(),
        .dimensions = request.dimensions,
    } } });
}

fn signalAction(
    self: *Registry,
    request: contracts.SignalRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = lookupSession(self, request.session_id, request.authority, .signal) orelse
        return sessionNotFound(self, .signal, request.session_id);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());
    switch (request.signal) {
        // ConPTY has no signal instruments; an interrupt is the ETX byte,
        // which the console interprets as Ctrl+C. Everything else takes the
        // tree down through the job.
        .interrupt => {
            const pty = &(session.pty orelse
                return self.failure(.session_lost, .signal, request.session_id));
            if (!writeToPty(pty.input, "\x03")) {
                return self.failure(.session_lost, .signal, request.session_id);
            }
        },
        .hangup, .quit, .terminate, .kill => {
            const child = session.child orelse
                return self.failure(.session_lost, .signal, request.session_id);
            child.terminate(1);
        },
    }
    return self.success(.{ .success = .{ .signal = .{
        .session = session.facts(),
        .signal = request.signal,
    } } });
}

fn closeAction(
    self: *Registry,
    request: contracts.CloseRequest,
) Allocator.Error!contracts.OwnedResult {
    const session = blk: {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const found = self.findLocked(request.session_id) orelse
            return sessionNotFound(self, .close, request.session_id);
        if (!Registry.authorityAllowed(found, request.authority, .close)) {
            return sessionNotFound(self, .close, request.session_id);
        }
        break :blk found;
    };
    // Both policies terminate the job: Windows console has no SIGHUP
    // equivalent to deliver for a graceful close. Documented in the module
    // comment.
    self.terminateSessionLocked(session);
    session.mutex.lockUncancelable(io_mod.getIo());
    defer session.mutex.unlock(io_mod.getIo());
    return self.success(.{ .success = .{ .close = .{
        .session = session.facts(),
        .policy = request.policy,
    } } });
}

// ---------------------------------------------------------------------------
// Integration tests. These drive the real ConPTY data path on a Windows host:
// a cmd.exe child runs inside the pseudoconsole, output flows back through the
// reader thread, and every action in the contract is exercised. On non-Windows
// hosts they skip; the backend is compiled only for Windows targets (the
// comptime reference in native_session.zig).
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_profile_user = "windows-session-test";
const test_durable_owner = "windows-session-test-owner";

fn testPrincipal(cwd: []const u8) contracts.Principal {
    return .{
        .profile_user = test_profile_user,
        .durable_session_id = test_durable_owner,
        .workspace_root = cwd,
        .cwd = cwd,
        .transport_role = .interactive,
        .backend = .native,
    };
}

fn testPersistence(cwd: []const u8) contracts.StartPersistence {
    return .{
        .grant = .{
            .principal = testPrincipal(cwd),
            .actor = .agent,
            .controls = .full(),
            .generation = .{ .value = 1 },
        },
        .proof = .{ .bytes = @splat(9) },
    };
}

fn testClaim(cwd: []const u8) contracts.AuthorityClaim {
    return .{
        .principal = testPrincipal(cwd),
        .actor = .agent,
        .generation = .{ .value = 1 },
        .proof = .{ .bytes = @splat(9) },
    };
}

const cmd_exe = "C:\\Windows\\System32\\cmd.exe";

test "conpty session round trip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cwd);

    var registry = Registry.init(alloc);
    defer registry.deinit();
    const cancelled = std.atomic.Value(bool).init(false);
    const claim = testClaim(cwd);

    // Start: cmd.exe echoes the start command and the reader thread picks it
    // up through the pseudoconsole output pipe.
    var start_result = try registry.executeAuthorized(.{ .start = .{
        .cwd = cwd,
        .command = "echo FXWIN-START",
        .shell = .{ .executable = .{ .path = cmd_exe } },
        .dimensions = .{ .columns = 80, .rows = 24 },
        .return_when = .{ .match = "FXWIN-START" },
        .wait_ceiling_ms = 15_000,
        .persistence = testPersistence(cwd),
    } }, &cancelled);
    defer start_result.deinit(alloc);
    try testing.expect(start_result == .success);
    const started = start_result.success.start;
    try testing.expect(started.outcome == .condition_met);
    const session_id = try alloc.dupe(u8, started.session.session_id);
    defer alloc.free(session_id);

    // Write a second command into the live shell and wait for its output.
    var write_result = try registry.executeAuthorized(.{ .write = .{
        .session_id = session_id,
        .payload = .{ .text = "echo FXWIN-SECOND\r\n" },
        .lease = .use,
        .authority = claim,
    } }, &cancelled);
    defer write_result.deinit(alloc);
    try testing.expect(write_result == .success);
    try testing.expect(write_result.success.write.accepted_bytes > 0);

    var wait_result = try registry.executeAuthorized(.{ .wait = .{
        .session_id = session_id,
        .return_when = .{ .match = "FXWIN-SECOND" },
        .safety_ceiling_ms = 15_000,
        .authority = claim,
    } }, &cancelled);
    defer wait_result.deinit(alloc);
    try testing.expect(wait_result == .success);
    try testing.expect(wait_result.success.wait.outcome == .condition_met);

    // Read the retained output from the beginning of the session.
    var read_result = try registry.executeAuthorized(.{ .read = .{
        .session_id = session_id,
        .cursor = .{ .segment = 1, .offset = 0 },
        .authority = claim,
    } }, &cancelled);
    defer read_result.deinit(alloc);
    try testing.expect(read_result == .success);
    try testing.expect(
        std.mem.indexOf(u8, read_result.success.read.output, "FXWIN-START") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, read_result.success.read.output, "FXWIN-SECOND") != null,
    );

    // A claim with the wrong proof must be indistinguishable from a missing
    // session.
    var denied = try registry.executeAuthorized(.{ .read = .{
        .session_id = session_id,
        .cursor = .{ .segment = 1, .offset = 0 },
        .authority = .{
            .principal = testPrincipal(cwd),
            .actor = .agent,
            .generation = .{ .value = 1 },
            .proof = .{ .bytes = @splat(4) },
        },
    } }, &cancelled);
    defer denied.deinit(alloc);
    try testing.expect(denied == .failure);
    try testing.expectEqual(
        contracts.StructuredErrorCode.session_not_found,
        denied.failure.code,
    );

    // Resize re-wraps through ResizePseudoConsole.
    var resize_result = try registry.executeAuthorized(.{ .resize = .{
        .session_id = session_id,
        .dimensions = .{ .columns = 100, .rows = 30 },
        .authority = claim,
    } }, &cancelled);
    defer resize_result.deinit(alloc);
    try testing.expect(resize_result == .success);
    try testing.expectEqual(
        @as(u16, 100),
        resize_result.success.resize.dimensions.columns,
    );

    // Inspect reflects the started command and working directory.
    var inspect_result = try registry.executeAuthorized(.{ .inspect = .{
        .session_id = session_id,
        .authority = claim,
    } }, &cancelled);
    defer inspect_result.deinit(alloc);
    try testing.expect(inspect_result == .success);
    const inspected = inspect_result.success.inspect;
    try testing.expect(inspected.command != null);
    try testing.expectEqualStrings("echo FXWIN-START", inspected.command.?);
    try testing.expectEqualStrings(cwd, inspected.cwd);

    // Interrupt is the ETX byte on Windows; the action succeeds.
    var signal_result = try registry.executeAuthorized(.{ .signal = .{
        .session_id = session_id,
        .signal = .interrupt,
        .authority = claim,
    } }, &cancelled);
    defer signal_result.deinit(alloc);
    try testing.expect(signal_result == .success);

    // Close terminates the job; the session stays listed as closed until the
    // registry is deinitialized, matching the POSIX shutdown contract.
    var close_result = try registry.executeAuthorized(.{ .close = .{
        .session_id = session_id,
        .policy = .force,
        .authority = claim,
    } }, &cancelled);
    defer close_result.deinit(alloc);
    try testing.expect(close_result == .success);
    try testing.expectEqual(
        contracts.Lifecycle.closed,
        close_result.success.close.session.lifecycle,
    );

    var list_result = try registry.executeAuthorized(.{ .list = .{} }, &cancelled);
    defer list_result.deinit(alloc);
    try testing.expect(list_result == .success);
    try testing.expectEqual(@as(usize, 1), list_result.success.list.sessions.len);
}

test "conpty session collects natural exit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cwd);

    var registry = Registry.init(alloc);
    defer registry.deinit();
    const cancelled = std.atomic.Value(bool).init(false);

    var start_result = try registry.executeAuthorized(.{ .start = .{
        .cwd = cwd,
        .command = "exit",
        .shell = .{ .executable = .{ .path = cmd_exe } },
        .return_when = .started,
        .wait_ceiling_ms = 10_000,
        .persistence = testPersistence(cwd),
    } }, &cancelled);
    defer start_result.deinit(alloc);
    try testing.expect(start_result == .success);
    const session_id = try alloc.dupe(
        u8,
        start_result.success.start.session.session_id,
    );
    defer alloc.free(session_id);

    // The shell exits on its own; the reader sees pipe EOF (ERROR_BROKEN_PIPE,
    // never a zero-byte read) and the wait reports a clean exit.
    var wait_result = try registry.executeAuthorized(.{ .wait = .{
        .session_id = session_id,
        .return_when = .exit,
        .safety_ceiling_ms = 15_000,
        .authority = testClaim(cwd),
    } }, &cancelled);
    defer wait_result.deinit(alloc);
    try testing.expect(wait_result == .success);
    try testing.expect(wait_result.success.wait.outcome == .exited);
    try testing.expectEqual(
        @as(i32, 0),
        wait_result.success.wait.outcome.exited,
    );
}
