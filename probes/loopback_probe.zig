//! Probe: does the loopback path work on a real Windows host?
//!
//! Build: zig build-exe probes/loopback_probe.zig -O ReleaseSafe
//!
//! Measured:
//! 1. std.Io.net listen on 127.0.0.1:0, client thread connects, request/reply.
//!    This is what the OAuth loopback listener uses today.
//! 2. A raw ws2_32 socket path with WSAPoll readiness before accept. This is
//!    the candidate replacement if (1) is unusable: it would sit behind a
//!    listener seam and reuse the existing HTTP parsing.
//!
//! Wine could not exercise any socket in this program; phase 3 documented why.

const std = @import("std");
const builtin = @import("builtin");

const af_inet: i32 = 2;
const sock_stream: i32 = 1;
const pollin: i16 = 0x0100;
const wsa_version_2_2: u16 = 0x0202;

const PollFd = extern struct { fd: usize, events: i16, revents: i16 };

const SockaddrIn = extern struct {
    family: u16 = 2,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};

const WsaData = extern struct {
    version: u16,
    high_version: u16,
    description: [257]u8,
    system_status: [129]u8,
    max_sockets: u16,
    max_udp_dg: u16,
    vendor_info: ?*anyopaque,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *WsaData) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, type_: i32, protocol: i32) callconv(.winapi) usize;
extern "ws2_32" fn htons(v: u16) callconv(.winapi) u16;
extern "ws2_32" fn bind(s: usize, addr: *const SockaddrIn, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(s: usize, backlog: i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockname(s: usize, addr: *SockaddrIn, len: *i32) callconv(.winapi) i32;
extern "ws2_32" fn connect(s: usize, addr: *const SockaddrIn, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(s: usize, addr: ?*SockaddrIn, len: ?*i32) callconv(.winapi) usize;
extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) i32;
extern "ws2_32" fn WSAPoll(fds: [*]PollFd, n: u32, timeout: i32) callconv(.winapi) i32;

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

fn rawSend(s: usize, bytes: []const u8) bool {
    const n = send(s, bytes.ptr, @intCast(bytes.len), 0);
    return n == @as(i32, @intCast(bytes.len));
}

fn rawRecv(s: usize, buffer: []u8) usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = recv(s, buffer.ptr + total, @intCast(buffer.len - total), 0);
        if (n <= 0) break;
        total += @intCast(n);
        break;
    }
    return total;
}

const RawShared = struct {
    port: u16,
    connected: bool = false,
    got_reply: bool = false,
};

fn rawClient(shared: *RawShared) void {
    const s = socket(af_inet, sock_stream, 0);
    if (s == @as(usize, @bitCast(@as(isize, -1)))) return;
    var addr = SockaddrIn{ .port = htons(shared.port), .addr = 0x0100_007f };
    if (connect(s, &addr, @sizeOf(SockaddrIn)) != 0) {
        _ = closesocket(s);
        return;
    }
    shared.connected = true;
    _ = rawSend(s, "raw-ping");
    var buffer: [64]u8 = undefined;
    const n = rawRecv(s, &buffer);
    if (std.mem.startsWith(u8, buffer[0..n], "raw-pong")) shared.got_reply = true;
    _ = closesocket(s);
}

fn rawProbe(alloc: std.mem.Allocator) bool {
    var data: WsaData = undefined;
    if (WSAStartup(wsa_version_2_2, &data) != 0) {
        std.debug.print("raw: WSAStartup failed\n", .{});
        return false;
    }
    const listener = socket(af_inet, sock_stream, 0);
    if (listener == @as(usize, @bitCast(@as(isize, -1)))) {
        std.debug.print("raw: socket failed\n", .{});
        return false;
    }

    var addr = SockaddrIn{ .port = 0, .addr = 0x0100_007f };
    if (bind(listener, &addr, @sizeOf(SockaddrIn)) != 0) {
        std.debug.print("raw: bind failed\n", .{});
        return false;
    }
    if (listen(listener, 4) != 0) {
        std.debug.print("raw: listen failed\n", .{});
        return false;
    }
    var name: SockaddrIn = .{};
    var name_len: i32 = @sizeOf(SockaddrIn);
    if (getsockname(listener, &name, &name_len) != 0) {
        std.debug.print("raw: getsockname failed\n", .{});
        return false;
    }
    const port = std.mem.bigToNative(u16, name.port);
    std.debug.print("2a. raw ws2_32 listen ok port={d}\n", .{port});

    const shared = alloc.create(RawShared) catch return false;
    shared.* = .{ .port = port };
    const client = std.Thread.spawn(.{}, rawClient, .{shared}) catch return false;

    var fds = [_]PollFd{.{ .fd = listener, .events = pollin, .revents = 0 }};
    const polled = WSAPoll(&fds, 1, 5000);
    const readable = polled > 0 and (fds[0].revents & pollin) != 0;
    std.debug.print("2b. raw WSAPoll ret={d} revents=0x{x} readable={}\n", .{
        polled, fds[0].revents, readable,
    });

    const accepted = accept(listener, null, null);
    var ok = accepted != @as(usize, @bitCast(@as(isize, -1)));
    if (ok) {
        var buffer: [64]u8 = undefined;
        const n = rawRecv(accepted, &buffer);
        std.debug.print("2c. raw accepted, read {d} bytes: \"{s}\"\n", .{ n, buffer[0..n] });
        ok = std.mem.startsWith(u8, buffer[0..n], "raw-ping");
        _ = rawSend(accepted, "raw-pong");
        _ = closesocket(accepted);
    }
    client.join();
    _ = closesocket(listener);

    const pass = ok and readable and shared.connected and shared.got_reply;
    std.debug.print("2d. raw client connected={} got_reply={} VERDICT: {s}\n", .{
        shared.connected, shared.got_reply, if (pass) "PASS" else "FAIL",
    });
    return pass;
}

fn stdNetProbe(io: std.Io) bool {
    var address = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch return false;
    var listener = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("1a. std.Io.net listen FAILED: {any}\n", .{err});
        return false;
    };
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    std.debug.print("1a. std.Io.net listen ok port={d}\n", .{port});

    const Client = struct {
        fn run(io_: std.Io, port_: u16, got: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
            var addr = std.Io.net.IpAddress.parse("127.0.0.1", port_) catch {
                failed.store(true, .seq_cst);
                return;
            };
            std.debug.print("   client: connecting\n", .{});
            var stream = addr.connect(io_, .{ .mode = .stream }) catch {
                std.debug.print("   client: connect FAILED\n", .{});
                failed.store(true, .seq_cst);
                return;
            };
            std.debug.print("   client: connected, sending\n", .{});
            {
                var wbuf: [256]u8 = undefined;
                var writer = stream.writer(io_, &wbuf);
                writer.interface.writeAll("stdnet-ping") catch {
                    std.debug.print("   client: writeAll FAILED\n", .{});
                    failed.store(true, .seq_cst);
                    stream.close(io_);
                    return;
                };
                writer.interface.flush() catch {
                    std.debug.print("   client: flush FAILED\n", .{});
                    failed.store(true, .seq_cst);
                    stream.close(io_);
                    return;
                };
            }
            std.debug.print("   client: sent, reading reply\n", .{});
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(io_, &rbuf);
            const n = reader.interface.readSliceShort(&rbuf) catch 0;
            std.debug.print("   client: read {d} bytes\n", .{n});
            if (std.mem.startsWith(u8, rbuf[0..n], "stdnet-pong")) {
                got.store(true, .seq_cst);
            } else {
                failed.store(true, .seq_cst);
            }
            stream.close(io_);
        }
    };

    var got = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    const client = std.Thread.spawn(.{}, Client.run, .{ io, port, &got, &failed }) catch return false;

    // Watchdog so a stuck transport cannot hang the harness.
    const Watchdog = struct {
        fn run() void {
            Sleep(15_000);
            std.debug.print("WATCHDOG: 15s elapsed, exiting\n", .{});
            std.process.exit(3);
        }
    };
    const watchdog = std.Thread.spawn(.{}, Watchdog.run, .{}) catch return false;
    watchdog.detach();

    var stream = listener.accept(io) catch |err| {
        std.debug.print("1b. std.Io.net accept FAILED: {any}\n", .{err});
        client.join();
        return false;
    };
    std.debug.print("1b. std.Io.net accept ok\n", .{});

    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const n = reader.interface.readSliceShort(&rbuf) catch 0;
    std.debug.print("1c. read {d} bytes: \"{s}\"\n", .{ n, rbuf[0..n] });
    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    writer.interface.writeAll("stdnet-pong") catch {};
    writer.interface.flush() catch {};
    stream.close(io);
    client.join();

    const pass = n > 0 and got.load(.seq_cst) and !failed.load(.seq_cst);
    std.debug.print("1d. client got_reply={} failed={} VERDICT: {s}\n", .{
        got.load(.seq_cst), failed.load(.seq_cst), if (pass) "PASS" else "FAIL",
    });
    return pass;
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) {
        std.debug.print("probe is windows-only\n", .{});
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Run the raw ws2_32 probe first: it is the decisive one, and the
    // std.Io.net probe hangs when its data path does not flow (a watchdog
    // bounds it, but the verdict below is already determined).
    const raw = rawProbe(alloc);
    const std_net = stdNetProbe(init.io);
    std.debug.print("OVERALL std.Io.net={s} raw_ws2_32={s}\n", .{
        if (std_net) "PASS" else "FAIL",
        if (raw) "PASS" else "FAIL",
    });
    if (!raw) std.process.exit(1);
}
