// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");
const io = source.net_io;
const Looper = source.net_looper.Looper;
const allocator = std.testing.allocator;
const Atomic = std.atomic.Value(usize);
const libc = struct {
    extern "c" fn usleep(c_uint) c_int;
    extern "c" fn close(std.c.fd_t) c_int;
};

fn configured(raw: ?*anyopaque, _: io.SocketDescriptor, _: ?*const io.ReachabilityInfo) callconv(.c) bool {
    const count: *usize = @ptrCast(@alignCast(raw.?));
    count.* += 1;
    return true;
}

fn finish(_: ?*anyopaque, _: ?Looper.Failure) void {}
fn barrier(_: ?*anyopaque) anyerror!void {}
fn wait(value: *const Atomic, expected: usize) !void {
    for (0..5000) |_| {
        if (value.load(.acquire) >= expected) return;
        _ = libc.usleep(1000);
    }
    return error.Timeout;
}
fn destination(link: *io.SocketWrapper, family: u8) !io.SocketAddress {
    var address = try link.localAddress(family);
    if (family == 4) {
        address.address[0] = 127;
        address.address[3] = 1;
    } else address.address[15] = 1;
    return address;
}
fn receive(link: *io.SocketWrapper, buf: []u8, address: *io.SocketAddress) !usize {
    for (0..5000) |_| {
        return link.receiveFrom(buf, address) catch |err| {
            if (err != error.WouldBlock) return err;
            _ = libc.usleep(1000);
            continue;
        };
    }
    return error.Timeout;
}
const Echo = struct {
    looper: *Looper,
    count: Atomic = .init(0),
    ipv4: Atomic = .init(0),
    ipv6: Atomic = .init(0),
    failures: Atomic = .init(0),
    pause_once: bool = false,
    fn read(raw: ?*anyopaque, packets: Looper.Packets, sources: ?[]const io.SocketAddress) anyerror!Looper.ReadAction {
        const self: *Echo = @ptrCast(@alignCast(raw.?));
        const addresses = sources orelse return error.MissingAddresses;
        try std.testing.expectEqual(packets.len, addresses.len);
        for (addresses) |address| {
            switch (address.family) {
                4 => {
                    _ = self.ipv4.fetchAdd(1, .release);
                },
                6 => {
                    _ = self.ipv6.fetchAdd(1, .release);
                },
                else => return error.UnexpectedFamily,
            }
        }
        for (packets, addresses) |packet, address| try self.looper.writeQueued(&.{packet}, .link, address);
        _ = self.count.fetchAdd(packets.len, .release);
        if (self.pause_once) {
            self.pause_once = false;
            return .pause;
        }
        return .keep;
    }
    fn failed(raw: ?*anyopaque, _: Looper.Failure) void {
        const self: *Echo = @ptrCast(@alignCast(raw.?));
        _ = self.failures.fetchAdd(1, .release);
    }
};

const TunProbe = struct {
    payload: ?[]const u8 = null,
    cleaned: Atomic = .init(0),
    fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn reset(_: *anyopaque) io.Error!void {}
    fn read(raw: *anyopaque, buf: []u8) io.Error!?usize {
        const self: *TunProbe = @ptrCast(@alignCast(raw));
        const payload = self.payload orelse return error.WouldBlock;
        @memcpy(buf[0..payload.len], payload);
        self.payload = null;
        return payload.len;
    }
    fn write(_: *anyopaque, bytes: []const u8, offset: usize) io.Error!usize {
        return bytes.len - offset;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *TunProbe = @ptrCast(@alignCast(raw));
        _ = self.cleaned.fetchAdd(1, .release);
    }
    fn lastError(_: *anyopaque) c_int {
        return 0;
    }
    const vtable = source.net_io_posix.POSIXInterface.Mock.VTable{
        .set_event_mask = mask,
        .reset_events = reset,
        .read = read,
        .write = write,
        .cleanup = cleanup,
        .last_error_code = lastError,
    };
};

test "v2 one UDP link echoes several peers across both address families" {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
    }
    var tun = TunProbe{};
    var loop = try Looper.initExperimental(allocator, .{ .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    try loop.start();
    try loop.attach(.{ .pair = .{ .tun = .{ .fd = fds[0], .io = .{ .mock = .{ .ptr = &tun, .vtable = &TunProbe.vtable } } } } });
    var configure_count: usize = 0;
    const server = try io.SocketWrapper.createDatagram(allocator, .{ .configure = configured, .context = &configure_count });
    try std.testing.expectEqual(@as(usize, 2), configure_count);
    try std.testing.expect(server.isUnconnected());
    try std.testing.expect(server.remoteAddress() == null);
    const descriptor = server.linkDescriptor();
    try std.testing.expect(descriptor.io == .socket);
    try std.testing.expect(descriptor.io.extraDescriptor().? != descriptor.fd);
    const v4 = try destination(server, 4);
    const v6 = try destination(server, 6);
    try std.testing.expectEqual(v4.port, v6.port);
    var echo = Echo{ .looper = &loop };
    loop.attach(.{ .pair = .{ .link = server.linkDescriptor() }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        server.destroy();
        return err;
    };
    try std.testing.expectError(error.LooperUnavailable, loop.writeQueued(&.{"address required"}, .link, null));
    const first = try io.SocketWrapper.createDatagram(allocator, .{ .ipv6 = false });
    defer first.destroy();
    const second = try io.SocketWrapper.createDatagram(allocator, .{ .ipv6 = false });
    defer second.destroy();
    const third = try io.SocketWrapper.createDatagram(allocator, .{ .ipv4 = false });
    defer third.destroy();
    _ = try first.sendTo("one", v4);
    _ = try second.sendTo("two", v4);
    _ = try third.sendTo("", v6);
    var buf: [32]u8 = undefined;
    var address: io.SocketAddress = undefined;
    var n = try receive(first, &buf, &address);
    try std.testing.expectEqualStrings("one", buf[0..n]);
    try std.testing.expectEqual(v4.port, address.port);
    n = try receive(second, &buf, &address);
    try std.testing.expectEqualStrings("two", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), try receive(third, &buf, &address));
    try std.testing.expectEqual(@as(u8, 6), address.family);
    try std.testing.expectEqual(v6.port, address.port);
    try loop.writeQueued(&.{ "batch one", "batch two" }, .link, try destination(first, 4));
    n = try receive(first, &buf, &address);
    try std.testing.expectEqualStrings("batch one", buf[0..n]);
    n = try receive(first, &buf, &address);
    try std.testing.expectEqualStrings("batch two", buf[0..n]);
    try loop.detach(.link);
    try std.testing.expect(!loop.isLinkAttached());
    try std.testing.expect(loop.isTunAttached());
    try loop.writeQueued(&.{"tun still usable"}, .tun, null);
    try loop.stop();
    try std.testing.expectEqual(@as(usize, 1), tun.cleaned.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), echo.count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), echo.ipv4.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), echo.ipv6.load(.acquire));
}

test "v2 UDP pause, resume and replacement apply to the logical link" {
    var loop = try Looper.initExperimental(allocator, .{ .max_read_count = 1, .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    try loop.start();
    const server = try io.SocketWrapper.createDatagram(allocator, .{});
    const v4 = try destination(server, 4);
    const v6 = try destination(server, 6);
    var echo = Echo{ .looper = &loop, .pause_once = true };
    try std.testing.expectError(error.MuxFailure, loop.attach(.{ .pair = .{ .tun = server.linkDescriptor() } }));
    // Failed attach retains ownership, so the same object can be attached correctly.
    loop.attach(.{ .pair = .{ .link = server.linkDescriptor() }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        server.destroy();
        return err;
    };
    const peer = try io.SocketWrapper.createDatagram(allocator, .{});
    defer peer.destroy();
    _ = try peer.sendTo("pause", v4);
    try wait(&echo.count, 1);
    try loop.performTask(.{ .callback = barrier });
    _ = try peer.sendTo("resume", v6);
    _ = libc.usleep(20000);
    try std.testing.expectEqual(@as(usize, 1), echo.count.load(.acquire));
    try loop.resumeReading(.link);
    try wait(&echo.count, 2);
    try loop.detach(.link);
    const replacement = try io.SocketWrapper.createDatagram(allocator, .{ .ipv4 = false });
    const new_address = try destination(replacement, 6);
    loop.attach(.{ .pair = .{ .link = replacement.linkDescriptor() }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        replacement.destroy();
        return err;
    };
    _ = try peer.sendTo("new", new_address);
    try wait(&echo.count, 3);
    try loop.stop();
}

test "v2 UDP truncation fails the link and permits replacement" {
    var loop = try Looper.initExperimental(allocator, .{ .link_buf_size = 4, .on_finish = .{ .callback = finish } });
    defer loop.deinit();
    try loop.start();
    var echo = Echo{ .looper = &loop };
    const server = try io.SocketWrapper.createDatagram(allocator, .{ .ipv6 = false });
    const address = try destination(server, 4);
    loop.attach(.{ .pair = .{ .link = server.linkDescriptor() }, .on_failure = .{ .context = &echo, .callback = Echo.failed } }) catch |err| {
        server.destroy();
        return err;
    };
    const peer = try io.SocketWrapper.createDatagram(allocator, .{ .ipv6 = false });
    defer peer.destroy();
    _ = try peer.sendTo("oversized", address);
    try wait(&echo.failures, 1);
    try loop.performTask(.{ .callback = barrier });
    try std.testing.expect(!loop.isLinkAttached());
    const replacement = try io.SocketWrapper.createDatagram(allocator, .{ .ipv6 = false });
    const new_address = try destination(replacement, 4);
    loop.attach(.{ .pair = .{ .link = replacement.linkDescriptor() }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        replacement.destroy();
        return err;
    };
    _ = try peer.sendTo("ok", new_address);
    var buf: [4]u8 = undefined;
    var from: io.SocketAddress = undefined;
    try std.testing.expectEqual(@as(usize, 2), try receive(peer, &buf, &from));
    try std.testing.expectEqualStrings("ok", buf[0..2]);
    try loop.stop();
}

fn allocationRollback(a: std.mem.Allocator) !void {
    const link = try io.SocketWrapper.createDatagram(a, .{});
    defer link.destroy();
}
test "unconnected socket wrapper rolls back ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, allocationRollback, .{});
}

test "unified read callback has no addresses for connected UDP and TUN" {
    const Probe = struct {
        count: Atomic = .init(0),
        fn read(raw: ?*anyopaque, packets: Looper.Packets, addresses: ?[]const io.SocketAddress) !Looper.ReadAction {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expect(addresses == null);
            try std.testing.expectEqual(@as(usize, 1), packets.len);
            try std.testing.expectEqualStrings("plain", packets[0]);
            _ = self.count.fetchAdd(1, .release);
            return .pause;
        }
    };
    inline for (.{ Looper.init, Looper.initExperimental }) |init| {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        defer {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
        }
        var tun = TunProbe{ .payload = "plain" };
        var probe = Probe{};
        var loop = try init(allocator, .{ .on_finish = .{ .callback = finish } });
        defer loop.deinit();
        try loop.start();
        try loop.attach(.{
            .pair = .{ .tun = .{ .fd = fds[0], .io = .{ .mock = .{ .ptr = &tun, .vtable = &TunProbe.vtable } } } },
            .on_read = .{ .context = &probe, .callback = Probe.read },
        });
        if (std.c.write(fds[1], "x", 1) != 1) return error.PipeWriteFailed;
        try wait(&probe.count, 1);

        const server = try io.SocketWrapper.createDatagram(allocator, .{ .ipv6 = false });
        defer server.destroy();
        const peer = try destination(server, 4);
        const client = (try io.SocketWrapper.create(allocator, .{
            .endpoint = .{ .address = "127.0.0.1", .proto = .init(.udp, peer.port) },
            .timeout_ms = 1000,
            .buf_size = 4096,
        })) orelse return error.SocketFailed;
        loop.attach(.{
            .pair = .{ .link = client.linkDescriptor() },
            .on_read = .{ .context = &probe, .callback = Probe.read },
        }) catch |err| {
            client.destroy();
            return err;
        };
        try loop.writeQueued(&.{"request"}, .link, peer);
        var buf: [32]u8 = undefined;
        var sender: io.SocketAddress = undefined;
        _ = try receive(server, &buf, &sender);
        _ = try server.sendTo("plain", sender);
        try wait(&probe.count, 2);
        try loop.stop();
    }
}

test "connected socket wrapper does not retain endpoint text" {
    const peer = try io.SocketWrapper.createDatagram(allocator, .{ .ipv6 = false });
    defer peer.destroy();
    const address = try destination(peer, 4);
    var text = "127.0.0.1".*;
    const socket = (try io.SocketWrapper.create(allocator, .{
        .endpoint = .{ .address = &text, .proto = .init(.udp, address.port) },
        .timeout_ms = 1000,
        .buf_size = 4096,
    })) orelse return error.SocketFailed;
    defer socket.destroy();
    @memset(&text, 'x');
    try std.testing.expectEqualDeep(address, socket.remoteAddress().?);
    try std.testing.expectEqual(io.SocketType.udp, socket.remote_endpoint.?.type);
    try std.testing.expect(!socket.isUnconnected());
    try std.testing.expectEqual(@as(usize, 5), try socket.linkDescriptor().io.writePacket("owned", 0, null));
    var buf: [32]u8 = undefined;
    var source_address: io.SocketAddress = undefined;
    const n = try receive(peer, &buf, &source_address);
    try std.testing.expectEqualStrings("owned", buf[0..n]);
}
