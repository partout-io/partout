// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("source").core.api;
const io = @import("source").net_io;
const io_posix = @import("source").net_io_posix;
const io_c = io.io_c;

const mapReadResult = io_posix.mapReadResult;
const mapWriteResult = io_posix.mapWriteResult;

test "maps native socket read results" {
    try std.testing.expectError(error.WouldBlock, mapReadResult(.link, io_c.PPIOErrorWouldBlock, false));
    try std.testing.expectEqual(@as(?usize, null), try mapReadResult(.link, 0, false));
    try std.testing.expectError(error.EndOfStream, mapReadResult(.link, 0, true));
    try std.testing.expectEqual(@as(?usize, 42), try mapReadResult(.link, 42, true));
}

test "maps native write backpressure results" {
    try std.testing.expectError(error.WouldBlock, mapWriteResult(.link, io_c.PPIOErrorWouldBlock, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.link, io_c.PPIOErrorNoBufs, false));
    try std.testing.expectError(error.LibcFailure, mapWriteResult(.link, io_c.PPIOErrorNoSpace, false));
    try std.testing.expectError(error.Backpressure, mapWriteResult(.tun, io_c.PPIOErrorNoSpace, true));
    try std.testing.expectEqual(@as(usize, 7), try mapWriteResult(.link, 7, false));
}

test "socket wrapper rejects an invalid remote address" {
    try std.testing.expect((try io.SocketWrapper.create(std.testing.allocator, .{ .address = " \t", .proto = api.EndpointProtocol.init(.udp, 1194) }, .{
        .timeout_ms = 0,
        .buf_size = 0,
    })) == null);
}

test "POSIX interface dispatches to owned sockets and tunnels" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    std.testing.refAllDecls(io_posix.POSIXInterface);
    const allocator = std.testing.allocator;
    const socket = try allocator.create(io_posix.SocketWrapper);
    socket.* = .{
        .allocator = allocator,
        .socket = null,
        .remote_endpoint = try io.SocketEndpoint.init(.{ .address = "127.0.0.1", .proto = .init(.udp, 1194) }),
        .closes_on_empty_read = false,
    };
    const tun = try io_posix.TunWrapper.create(std.testing.allocator, null);
    const native_socket = socket.linkDescriptor().io;
    defer native_socket.cleanup();
    try std.testing.expectError(error.LibcFailure, tun.tunDescriptor());
    const native_tun = tun.nativeIO();
    defer tun.destroy();
    try std.testing.expect(native_tun.tun == tun);
    try std.testing.expect(native_socket.socket == socket);
    try std.testing.expect(native_socket == .socket);
    try std.testing.expect(native_tun == .tun);
    try native_tun.setEventMask(true, true);
    try native_tun.resetEvents();
    // Invalid offsets are rejected before reaching the native handles.
    for ([_]io_posix.POSIXInterface{ native_socket, native_tun }) |native| {
        try std.testing.expectError(error.InvalidOffset, native.write("", 1));
    }
}

test "TUN looper descriptor is made nonblocking by the wrapper" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const libc = struct {
        extern "c" fn close(c_int) c_int;
    };
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    const before: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fds[0], std.c.F.GETFL))));
    try std.testing.expect(!before.NONBLOCK);
    const tun = try io_posix.TunWrapper.create(std.testing.allocator, null);
    defer tun.destroy();
    // Borrow the pipe solely to exercise descriptor preparation, without a native TUN.
    tun.test_descriptor = .{ .fd = fds[0], .io = tun.nativeIO() };
    const descriptor = try tun.tunDescriptor();
    var waiter = @import("source").net.Waiter.init() orelse return error.TestUnexpectedResult;
    defer waiter.deinit();
    var mutex: @import("source").core.Mutex = .{};
    defer mutex.deinit();
    mutex.lock();
    defer mutex.unlock();
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "!", 1));
    try std.testing.expect(try descriptor.io.waitForReadiness(false, &waiter, &mutex));
    tun.test_descriptor = null;
    try std.testing.expectEqual(fds[0], descriptor.fd);
    try std.testing.expect(descriptor.io.tun == tun);
    const after: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fds[0], std.c.F.GETFL))));
    try std.testing.expect(after.NONBLOCK);
}

test "socket argument errors are rejected before native I/O" {
    const endpoint = try io.SocketEndpoint.init(.{ .address = "127.0.0.1", .proto = .init(.udp, 1194) });
    var socket = io_posix.SocketWrapper{
        .allocator = std.testing.allocator,
        .socket = null,
        .remote_endpoint = endpoint,
    };
    const native = io_posix.POSIXInterface{ .socket = &socket };
    var buf: [8]u8 = undefined;
    var address: io.SocketAddress = undefined;

    try std.testing.expectError(error.InvalidSocketMode, socket.receiveFrom(&buf, &address));
    try std.testing.expectError(error.InvalidSocketMode, socket.sendTo("payload", endpoint.address));
    try std.testing.expectError(error.InvalidOffset, native.write("payload", 8));

    socket.remote_endpoint = null;
    try std.testing.expectError(error.InvalidSocketMode, native.read(&buf));
    try std.testing.expectError(error.InvalidSocketMode, native.write("payload", 0));
    try std.testing.expectError(error.MissingDestination, native.writePacket("payload", 0, null));
    for ([_]u8{ 0, 5, 255 }) |family| {
        var invalid_address = endpoint.address;
        invalid_address.family = family;
        try std.testing.expectError(error.InvalidAddressFamily, socket.sendTo("payload", invalid_address));
        try std.testing.expectError(error.InvalidAddressFamily, native.writePacket("payload", 0, invalid_address));
    }

    // Valid arguments reach the invalid native handle and retain its native error.
    try std.testing.expectError(error.LibcFailure, socket.sendTo("payload", endpoint.address));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.c.E.BADF)), native.lastErrorCode());
}

test "looper owns heap TUN wrapper and closes transferred handle exactly once" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Probe = struct {
        closed: usize = 0,
        fn finish(_: ?*anyopaque, _: ?@import("source").net.Looper.Failure) void {}
        fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
        fn reset(_: *anyopaque) io.Error!void {}
        fn read(_: *anyopaque, _: []u8) io.Error!?usize {
            return error.WouldBlock;
        }
        fn write(_: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
            return data.len - offset;
        }
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.closed += 1;
        }
        fn lastError(_: *anyopaque) c_int {
            return 0;
        }
        const vtable = io_posix.POSIXInterface.Mock.VTable{
            .set_event_mask = mask,
            .reset_events = reset,
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .last_error_code = lastError,
        };
    };
    const libc = struct {
        extern "c" fn close(c_int) c_int;
    };
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    var probe = Probe{};
    var loop = try @import("source").net.Looper.initExperimental(std.testing.allocator, .{ .on_finish = .{ .callback = Probe.finish } });
    defer loop.deinit();
    {
        const tun = try io_posix.TunWrapper.create(std.testing.allocator, null);
        tun.test_descriptor = .{ .fd = fds[0], .io = .{ .mock = .{ .ptr = &probe, .vtable = &Probe.vtable } } };
        const descriptor = try tun.tunDescriptor();
        try std.testing.expectError(error.LooperUnavailable, loop.attach(.{ .pair = .{ .tun = descriptor } }));
        try std.testing.expect(!tun.is_closed);
        try loop.start();
        try loop.attach(.{ .pair = .{ .tun = descriptor } });
        try std.testing.expectEqual(@as(usize, 0), probe.closed);
    }
    try loop.detach(.tun);
    try std.testing.expectEqual(@as(usize, 1), probe.closed);
    try loop.stop();
    try std.testing.expectEqual(@as(usize, 1), probe.closed);
}

test "POSIX readiness wait releases the ownership lock while waiting for UDP" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const core = @import("source").core;
    const local = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.TestUnexpectedResult;
    defer local.destroy();
    const peer = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.TestUnexpectedResult;
    defer peer.destroy();
    var destination = try local.localAddress();
    destination.address[0..4].* = .{ 127, 0, 0, 1 };
    const native = local.linkDescriptor().io;
    var waiter = @import("source").net.Waiter.init() orelse return error.TestUnexpectedResult;
    defer waiter.deinit();
    var mutex: core.Mutex = .{};
    defer mutex.deinit();
    {
        mutex.lock();
        defer mutex.unlock();
        try std.testing.expect(try native.waitForReadiness(true, &waiter, &mutex));
    }
    const Sender = struct {
        fn send(lock: *core.Mutex, socket: *io.SocketWrapper, address: io.SocketAddress) void {
            lock.lock();
            defer lock.unlock();
            _ = socket.sendTo("udp", address) catch unreachable;
        }
    };
    mutex.lock();
    const thread = try std.Thread.spawn(.{}, Sender.send, .{ &mutex, peer, destination });
    const ready = native.waitForReadiness(false, &waiter, &mutex);
    mutex.unlock();
    thread.join();
    try std.testing.expect(try ready);
    var packet: [16]u8 = undefined;
    var address: io.SocketAddress = undefined;
    try std.testing.expectEqual(@as(usize, 3), try native.readPacket(&packet, &address));
    try std.testing.expectEqualStrings("udp", packet[0..3]);
}
