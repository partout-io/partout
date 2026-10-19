// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");
const test_helpers = @import("looper_test_helpers.zig");
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

fn wait(loop: ?*Looper, value: *const Atomic, expected: usize) !void {
    for (0..if (loop != null) @as(usize, 500) else 5000) |_| {
        if (value.load(.acquire) >= expected) return;
        if (loop) |caller| {
            try std.testing.expect(try test_helpers.poll(caller, 10));
        } else {
            _ = libc.usleep(1000);
        }
    }
    return error.Timeout;
}
fn destination(link: *io.SocketWrapper, family: u8) !io.SocketAddress {
    const local = try link.localAddress();
    var address = std.mem.zeroes(io.SocketAddress);
    address.family = family;
    address.port = local.port;
    if (family == 4) {
        address.address[0] = 127;
        address.address[3] = 1;
    } else address.address[15] = 1;
    return address;
}
fn receive(loop: ?*Looper, link: *io.SocketWrapper, buf: []u8, address: *io.SocketAddress) !usize {
    for (0..if (loop != null) @as(usize, 500) else 5000) |_| {
        return link.receiveFrom(buf, address) catch |err| {
            if (err != error.WouldBlock) return err;
            if (loop) |caller| {
                try std.testing.expect(try test_helpers.poll(caller, 10));
            } else {
                _ = libc.usleep(1000);
            }
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
    fn read(raw: ?*anyopaque, packets: io.Packets, sources: ?[]const io.SocketAddress) anyerror!io.ReadAction {
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
        for (packets, addresses) |packet, address| try self.looper.write(&.{packet}, .link, address);
        _ = self.count.fetchAdd(packets.len, .release);
        if (self.pause_once) {
            self.pause_once = false;
            return .pause;
        }
        return .keep;
    }
    fn failed(raw: ?*anyopaque, _: io.Failure) void {
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

test "one UDP link echoes several peers across both address families" {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
    }
    var tun = TunProbe{};

    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{
        .mux = wake.handle,
    });
    defer loop.deinit();

    try loop.attach(.{ .pair = .{ .tun = .{ .fd = fds[0], .io = .{ .mock = .{ .ptr = &tun, .vtable = &TunProbe.vtable } } } } });
    var configure_count: usize = 0;
    const server = (try io.SocketWrapper.create(allocator, null, .{ .configure = configured, .configure_ctx = &configure_count })) orelse return error.SocketFailed;
    try std.testing.expectEqual(@as(usize, 1), configure_count);
    try std.testing.expect(server.isUnconnected());
    try std.testing.expect(server.remoteAddress() == null);
    const descriptor = server.linkDescriptor();
    try std.testing.expect(descriptor.io == .socket);
    const v4 = try destination(server, 4);
    const v6 = try destination(server, 6);
    try std.testing.expectEqual(v4.port, v6.port);
    var echo = Echo{ .looper = &loop };
    loop.attach(.{ .pair = .{ .link = server.linkDescriptor() }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        server.destroy();
        return err;
    };
    try std.testing.expectError(error.MissingDestination, loop.write(&.{"address required"}, .link, null));
    const first = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    defer first.destroy();
    const second = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    defer second.destroy();
    const third = (try io.SocketWrapper.create(allocator, null, .{ .ipv4 = false })) orelse return error.SocketFailed;
    defer third.destroy();
    _ = try first.sendTo("one", v4);
    _ = try second.sendTo("two", v4);
    _ = try third.sendTo("", v6);
    var buf: [32]u8 = undefined;
    var address: io.SocketAddress = undefined;
    var n = try receive(&loop, first, &buf, &address);
    try std.testing.expectEqualStrings("one", buf[0..n]);
    try std.testing.expectEqual(v4.port, address.port);
    n = try receive(&loop, second, &buf, &address);
    try std.testing.expectEqualStrings("two", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), try receive(&loop, third, &buf, &address));
    try std.testing.expectEqual(@as(u8, 6), address.family);
    try std.testing.expectEqual(v6.port, address.port);
    try loop.write(&.{ "batch one", "batch two" }, .link, try destination(first, 4));
    n = try receive(&loop, first, &buf, &address);
    try std.testing.expectEqualStrings("batch one", buf[0..n]);
    n = try receive(&loop, first, &buf, &address);
    try std.testing.expectEqualStrings("batch two", buf[0..n]);
    try loop.detach(.link);
    try std.testing.expect(!loop.isLinkAttached());
    try std.testing.expect(loop.isTunAttached());
    try loop.write(&.{"tun still usable"}, .tun, null);
    try loop.stop();
    try std.testing.expectEqual(@as(usize, 1), tun.cleaned.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), echo.count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), echo.ipv4.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), echo.ipv6.load(.acquire));
}

test "UDP pause, resume and replacement apply to the logical link" {
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{
        .mux = wake.handle,
        .max_read_count = 1,
    });
    defer loop.deinit();

    const server = (try io.SocketWrapper.create(allocator, null, .{})) orelse return error.SocketFailed;
    const v4 = try destination(server, 4);
    const v6 = try destination(server, 6);
    var echo = Echo{ .looper = &loop, .pause_once = true };
    try std.testing.expectError(error.MuxFailure, loop.attach(.{ .pair = .{ .tun = server.linkDescriptor() } }));
    // Failed attach retains ownership, so the same object can be attached correctly.
    loop.attach(.{ .pair = .{ .link = server.linkDescriptor() }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        server.destroy();
        return err;
    };
    const peer = (try io.SocketWrapper.create(allocator, null, .{})) orelse return error.SocketFailed;
    defer peer.destroy();
    _ = try peer.sendTo("pause", v4);
    try wait(&loop, &echo.count, 1);
    try std.testing.expect(try test_helpers.poll(&loop, 0));
    _ = try peer.sendTo("resume", v6);
    try std.testing.expect(try test_helpers.poll(&loop, 20));
    try std.testing.expectEqual(@as(usize, 1), echo.count.load(.acquire));
    try loop.resumeReading(.link);
    try wait(&loop, &echo.count, 2);
    try loop.detach(.link);
    const replacement = (try io.SocketWrapper.create(allocator, null, .{ .ipv4 = false })) orelse return error.SocketFailed;
    const new_address = try destination(replacement, 6);
    loop.attach(.{ .pair = .{ .link = replacement.linkDescriptor() }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        replacement.destroy();
        return err;
    };
    _ = try peer.sendTo("new", new_address);
    try wait(&loop, &echo.count, 3);
    try loop.stop();
}

test "UDP truncation drops the packet and retains the link" {
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var loop = try Looper.init(allocator, .{
        .mux = wake.handle,
        .link_buf_size = 4,
    });
    defer loop.deinit();

    var echo = Echo{ .looper = &loop };
    const server = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    const address = try destination(server, 4);
    loop.attach(.{ .pair = .{ .link = server.linkDescriptor() }, .on_failure = .{ .context = &echo, .callback = Echo.failed }, .on_read = .{ .context = &echo, .callback = Echo.read } }) catch |err| {
        server.destroy();
        return err;
    };
    const peer = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    defer peer.destroy();
    _ = try peer.sendTo("oversized", address);
    _ = try peer.sendTo("ok", address);
    var buf: [4]u8 = undefined;
    var from: io.SocketAddress = undefined;
    try std.testing.expectEqual(@as(usize, 2), try receive(&loop, peer, &buf, &from));
    try std.testing.expectEqualStrings("ok", buf[0..2]);
    try std.testing.expect(loop.isLinkAttached());
    try std.testing.expectEqual(@as(usize, 0), echo.failures.load(.acquire));
    try loop.stop();
}

fn allocationRollback(a: std.mem.Allocator) !void {
    const link = (try io.SocketWrapper.create(a, null, .{})) orelse return error.SocketFailed;
    defer link.destroy();
}
test "unconnected socket wrapper rolls back ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, allocationRollback, .{});
}

test "unified read callback has no addresses for connected UDP and TUN" {
    const Probe = struct {
        count: Atomic = .init(0),
        fn read(raw: ?*anyopaque, packets: io.Packets, addresses: ?[]const io.SocketAddress) !io.ReadAction {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expect(addresses == null);
            try std.testing.expectEqual(@as(usize, 1), packets.len);
            try std.testing.expectEqualStrings("plain", packets[0]);
            _ = self.count.fetchAdd(1, .release);
            return .pause;
        }
    };
    {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        defer {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
        }
        var tun = TunProbe{ .payload = "plain" };
        var probe = Probe{};

        const wake = try test_helpers.Mux.init();
        defer wake.deinit();
        var loop = try Looper.init(allocator, .{
            .mux = wake.handle,
        });
        defer loop.deinit();
        const caller = &loop;

        try loop.attach(.{
            .pair = .{ .tun = .{ .fd = fds[0], .io = .{ .mock = .{ .ptr = &tun, .vtable = &TunProbe.vtable } } } },
            .on_read = .{ .context = &probe, .callback = Probe.read },
        });
        if (std.c.write(fds[1], "x", 1) != 1) return error.PipeWriteFailed;
        try wait(caller, &probe.count, 1);

        const server = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
        defer server.destroy();
        const peer = try destination(server, 4);
        const client = (try io.SocketWrapper.create(allocator, .{ .address = "127.0.0.1", .proto = .init(.udp, peer.port) }, .{
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
        try loop.write(&.{"request"}, .link, peer);
        var buf: [32]u8 = undefined;
        var sender: io.SocketAddress = undefined;
        _ = try receive(caller, server, &buf, &sender);
        _ = try server.sendTo("plain", sender);
        try wait(caller, &probe.count, 2);
        try loop.stop();
    }
}

test "connected socket wrapper does not retain endpoint text" {
    const peer = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    defer peer.destroy();
    const address = try destination(peer, 4);
    var text = "127.0.0.1".*;
    const socket = (try io.SocketWrapper.create(allocator, .{ .address = &text, .proto = .init(.udp, address.port) }, .{
        .timeout_ms = 1000,
        .buf_size = 4096,
    })) orelse return error.SocketFailed;
    defer socket.destroy();
    @memset(&text, 'x');
    try std.testing.expectEqualDeep(address, socket.remoteAddress().?);
    try std.testing.expectEqual(source.core.api.IPSocketType.udp, socket.remote_endpoint.?.type);
    try std.testing.expect(!socket.isUnconnected());
    try std.testing.expectEqual(@as(usize, 5), try socket.linkDescriptor().io.writePacket("owned", 0, null));
    var buf: [32]u8 = undefined;
    var source_address: io.SocketAddress = undefined;
    const n = try receive(null, peer, &buf, &source_address);
    try std.testing.expectEqualStrings("owned", buf[0..n]);
}

test "connected socket wrapper resolves hostnames and retains the selected peer" {
    const peer = (try io.SocketWrapper.create(allocator, null, .{})) orelse return error.SocketFailed;
    defer peer.destroy();
    const bound = try peer.localAddress();
    var hostname = "localhost".*;
    const socket = (try io.SocketWrapper.create(allocator, .{ .address = &hostname, .proto = .init(.udp, bound.port) }, .{
        .timeout_ms = 1000,
    })) orelse return error.SocketFailed;
    defer socket.destroy();
    @memset(&hostname, 'x');
    try std.testing.expect(!socket.isUnconnected());
    const remote = socket.remoteAddress().?;
    try std.testing.expectEqualDeep(try destination(peer, remote.family), remote);
    const native = socket.linkDescriptor().io;
    try std.testing.expectEqual(@as(usize, 7), try native.writePacket("request", 0, null));
    var buf: [32]u8 = undefined;
    var sender: io.SocketAddress = undefined;
    const n = try receive(null, peer, &buf, &sender);
    try std.testing.expectEqualStrings("request", buf[0..n]);
    _ = try peer.sendTo("reply", sender);
    for (0..5000) |_| {
        const count = native.read(&buf) catch |err| {
            if (err != error.WouldBlock) return err;
            _ = libc.usleep(1000);
            continue;
        };
        try std.testing.expectEqualStrings("reply", buf[0..count.?]);
        return;
    }
    return error.Timeout;
}

test "unconnected socket family restrictions remain explicit" {
    try std.testing.expect((try io.SocketWrapper.create(allocator, null, .{ .ipv4 = false, .ipv6 = false })) == null);
    const v4 = (try io.SocketWrapper.create(allocator, null, .{ .ipv6 = false })) orelse return error.SocketFailed;
    defer v4.destroy();
    const v6 = (try io.SocketWrapper.create(allocator, null, .{ .ipv4 = false })) orelse return error.SocketFailed;
    defer v6.destroy();
    try std.testing.expectEqual(@as(u8, 4), (try v4.localAddress()).family);
    try std.testing.expectEqual(@as(u8, 6), (try v6.localAddress()).family);
    try std.testing.expectError(error.DatagramDropped, v4.sendTo("wrong family", try destination(v6, 6)));
    try std.testing.expectError(error.DatagramDropped, v6.sendTo("wrong family", try destination(v4, 4)));
}
