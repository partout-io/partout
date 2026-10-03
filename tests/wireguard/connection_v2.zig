// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
const std = @import("std");
const builtin = @import("builtin");
const source = @import("source");
const api = source.core.api;
const io = source.net_io;
const backend_mod = source.wireguard_internal.backend;
const c = @import("wireguard_c");
const libc = struct {
    extern "c" fn read(c_int, [*]u8, usize) isize;
    extern "c" fn write(c_int, [*]const u8, usize) isize;
    extern "c" fn close(c_int) c_int;
    extern "c" fn usleep(c_uint) c_int;
};
const Probe = struct {
    fd: c_int,
    requested_port: u16,
    tun_reads: std.atomic.Value(usize) = .init(0),
    link_reads: std.atomic.Value(usize) = .init(0),
    tun_calls: std.atomic.Value(usize) = .init(0),
    link_calls: std.atomic.Value(usize) = .init(0),
    writes: std.atomic.Value(usize) = .init(0),
    cleaned: usize = 0,
    var current: *Probe = undefined;
    fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn reset(_: *anyopaque) io.Error!void {}
    fn read(raw: *anyopaque, buf: []u8) io.Error!?usize {
        const self: *Probe = @ptrCast(@alignCast(raw));
        const size = libc.read(self.fd, buf.ptr, buf.len);
        if (size < 0) return error.WouldBlock;
        return @intCast(size);
    }
    fn write(raw: *anyopaque, bytes: []const u8, offset: usize) io.Error!usize {
        const self: *Probe = @ptrCast(@alignCast(raw));
        std.debug.assert(std.mem.eql(u8, bytes[offset..], &.{ 0x60, 4, 5, 6 }));
        _ = self.writes.fetchAdd(1, .release);
        return bytes.len - offset;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.cleaned += 1;
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
    fn receiveTun(_: i32, packets: [*c]const c.wg_packet, count: u32) callconv(.c) i32 {
        std.debug.assert(count > 0 and count <= c.WG_IO_MAX_BATCH);
        for (packets[0..count]) |packet| std.debug.assert(packet.size == 4 and packet.data[0] == 0x45);
        _ = current.tun_reads.fetchAdd(count, .release);
        _ = current.tun_calls.fetchAdd(1, .release);
        return 0;
    }
    fn receiveLink(_: i32, packets: [*c]const c.wg_packet, endpoints: [*c]const c.wg_endpoint, count: u32) callconv(.c) i32 {
        std.debug.assert(count > 0 and count <= c.WG_IO_MAX_BATCH);
        for (packets[0..count], endpoints[0..count]) |packet, endpoint| std.debug.assert(packet.size == 3 and packet.data[0] == 1 and endpoint.port != 0);
        _ = current.link_reads.fetchAdd(count, .release);
        _ = current.link_calls.fetchAdd(1, .release);
        return 0;
    }
    fn submitBatches(raw: ?*anyopaque) anyerror!void {
        const connection: *source.net_connection.Connection = @ptrCast(@alignCast(raw.?));
        const count = c.WG_IO_MAX_BATCH + 1;
        const tun_packets = [_][]const u8{&.{ 0x45, 1, 2, 3 }} ** count;
        const link_packets = [_][]const u8{&.{ 1, 2, 3 }} ** count;
        const addresses = [_]io.SocketAddress{.{ .family = 4, .port = 51820, .address = .{ 192, 0, 2, 1 } ++ .{0} ** 12 }} ** count;
        try std.testing.expectEqual(.keep, connection.submitPackets(.tun, &tun_packets, null));
        try std.testing.expectEqual(.keep, connection.submitPackets(.link, &link_packets, &addresses));
        try std.testing.expectEqual(count, current.tun_reads.load(.acquire));
        try std.testing.expectEqual(count, current.link_reads.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), current.tun_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), current.link_calls.load(.acquire));
    }
    fn setTunnel(raw: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) source.net_sandbox.TunnelController.Error!io.TunWrapper {
        const ctrl: *source.mock.MockTunnelController = @ptrCast(@alignCast(raw.?));
        _ = try ctrl.interface().setTunnelSettings(info);
        var tun = io.TunWrapper.init(null);
        tun.test_descriptor = .{ .fd = current.fd, .io = .{ .mock = .{ .ptr = current, .vtable = &vtable } } };
        return tun;
    }
    fn createSocket(_: ?*anyopaque, allocator: std.mem.Allocator, endpoint: ?api.ExtendedEndpoint, _: ?io.ReachabilityInfo, _: c_int, port: u16) source.net_sandbox.SocketFactory.Error!io.LinkDescriptor {
        std.debug.assert(endpoint == null);
        std.debug.assert(port == current.requested_port);
        const socket = try io.SocketWrapper.create(allocator, endpoint, .{ .port = port }) orelse return error.LinkNotActive;
        return socket.linkDescriptor();
    }
    fn barrier(_: ?*anyopaque) anyerror!void {}
};
fn wait(counter: *const std.atomic.Value(usize), target: usize) !void {
    for (0..1000) |_| {
        if (counter.load(.acquire) >= target) return;
        _ = libc.usleep(1000);
    }
    return error.Timeout;
}

test "WireGuard v2 daemon owns link and TUN across retry, packets, path changes and termination" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const mock = source.mock;
    const reservation = (try io.SocketWrapper.create(allocator, null, .{})).?;
    const requested_port = (try reservation.localAddress()).port;
    reservation.destroy();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
    }
    var probe = Probe{ .fd = fds[0], .requested_port = requested_port };
    Probe.current = &probe;
    var fake = FakeBackend{ .fail_turn_on_number = 1 };
    var backend_table = fake_backend_vtable;
    backend_table.receive_datagrams = Probe.receiveLink;
    backend_table.receive_tun_packets = Probe.receiveTun;
    var ctx = source.wireguard_connection_v2.ConnectionContext.init(.{ .ptr = &fake, .vtable = &backend_table });
    var registry = try source.net_connection.ConnectionRegistry.init(allocator, &.{.{ .ptr = &ctx, .vtable = &source.wireguard_exports.connection_v2_vtable }});
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var controller_table = controller.interface().vtable.*;
    controller_table.set_tunnel_settings = Probe.setTunnel;
    var monitor = mock.MockNetworkMonitor{};
    var factory = mock.noopSocketFactory();
    var factory_table = factory.vtable.*;
    factory_table.create = Probe.createSocket;
    factory.vtable = &factory_table;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer profile.deinit(allocator);
    const module = @constCast(api.findActiveConnectionModule(&profile).?);
    module.WireGuard.configuration.?.interface.listen_port = requested_port;
    const sut = try source.net_daemon_v2.Daemon.create(allocator, &profile, .{
        .objects = .{ .registry = &registry, .controller = .{ .ptr = &controller, .vtable = &controller_table }, .resolver = mock.noopDNSResolver(), .factory = factory, .monitor = monitor.interface() },
        .options = .{ .connection_options = .{ .min_data_count_interval = 10 }, .reconnection_delay_ms = 60_000 },
    });
    defer sut.destroy();
    try sut.start();
    defer sut.stop();
    const owner = sut.implementation.connection;
    try std.testing.expect(owner.endpoint_resolver == null);
    try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expect(!owner.looper.isLinkAttached());
    try owner.actor.perform(void, .evaluateConnection);
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expect(owner.tunnel != null and owner.looper.isTunAttached() and owner.looper.isLinkAttached());
    try std.testing.expectEqual(@as(usize, 2), fake.turn_on_count);
    try std.testing.expect(fake.link != null and fake.tun != null);
    try std.testing.expectEqual(requested_port, fake.link.?.local_port);
    try wait(&fake.counts, 2);
    var connection = owner.connection.?;
    try owner.looper.perform(void, &connection, Probe.submitBatches);
    _ = libc.write(fds[1], &.{ 0x45, 1, 2, 3 }, 4);
    try wait(&probe.tun_reads, c.WG_IO_MAX_BATCH + 2);
    var packet = [_]u8{ 0x60, 4, 5, 6 };
    var output = [_]c.wg_packet{.{ .data = &packet, .size = packet.len }} ** c.WG_IO_MAX_BATCH;
    // Validate the entire batch before queueing any write.
    output[1].data = null;
    try std.testing.expectEqual(@as(i32, c.WG_IO_INVALID), fake.tun.?.write.?(fake.context, &output, output.len));
    try owner.looper.perform(void, null, Probe.barrier);
    try std.testing.expectEqual(@as(usize, 0), probe.writes.load(.acquire));
    output[1].data = &packet;
    try std.testing.expectEqual(@as(i32, 0), fake.tun.?.write.?(fake.context, &output, output.len));
    packet[0] = 0;
    try wait(&probe.writes, output.len);
    const peer = (try io.SocketWrapper.create(allocator, null, .{})).?;
    defer peer.destroy();
    const peer_port = (try peer.localAddress()).port;
    const destination = c.wg_endpoint{ .family = 4, .port = peer_port, .address = .{ 127, 0, 0, 1 } ++ .{0} ** 12 };
    var first = [_]u8{ 7, 8, 9 };
    var second = [_]u8{ 10, 11, 12 };
    const datagrams = [_]c.wg_packet{ .{ .data = &first, .size = first.len }, .{ .data = &second, .size = second.len } };
    try std.testing.expectEqual(@as(i32, 0), fake.link.?.write.?(fake.context, &datagrams, datagrams.len, &destination));
    first[0] = 0;
    second[0] = 0;
    for ([_][]const u8{ &.{ 7, 8, 9 }, &.{ 10, 11, 12 } }) |expected| {
        var received: [16]u8 = undefined;
        var sender: io.SocketAddress = undefined;
        var size: ?usize = null;
        for (0..1000) |_| {
            size = peer.receiveFrom(&received, &sender) catch |err| {
                if (err != error.WouldBlock) return err;
                _ = libc.usleep(1000);
                continue;
            };
            break;
        }
        try std.testing.expect(size != null);
        try std.testing.expectEqualSlices(u8, expected, received[0..size.?]);
        try std.testing.expectEqual(fake.link.?.local_port, sender.port);
    }
    var address = std.mem.zeroes(io.SocketAddress);
    address.family = 4;
    address.port = fake.link.?.local_port;
    address.address[0] = 127;
    address.address[3] = 1;
    _ = try peer.sendTo(&.{ 1, 2, 3 }, address);
    try wait(&probe.link_reads, c.WG_IO_MAX_BATCH + 2);
    monitor.onBetterPath();
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expectEqual(@as(usize, 1), probe.cleaned);
    try std.testing.expect(!owner.looper.isTunAttached() and !owner.looper.isLinkAttached());
    try owner.actor.perform(void, .resumeGate);
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
    try owner.looper.stop();
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
    sut.stop();
    try std.testing.expectEqual(@as(usize, 3), fake.turn_off_count);
    try std.testing.expectEqual(@as(usize, 3), probe.cleaned);
}

const FakeBackend = struct {
    link: ?@import("wireguard_c").wg_passive_link = null,
    tun: ?@import("wireguard_c").wg_passive_tun = null,
    context: ?*anyopaque = null,
    counts: std.atomic.Value(usize) = .init(0),
    turn_on_count: usize = 0,
    turn_off_count: usize = 0,
    fail_turn_on_number: ?usize = null,
};

const fake_backend_vtable = backend_mod.Backend.VTable{
    .turn_on = fakeTurnOn,
    .turn_off = fakeTurnOff,
    .get_config = fakeGetConfig,
    .set_config = fakeSetConfig,
    .socket_descriptors = fakeSocketDescriptors,
    .bump_sockets = fakeBumpSockets,
    .disable_roaming = fakeDisableRoaming,
};

fn fakeTurnOn(
    ptr: ?*anyopaque,
    _: std.mem.Allocator,
    _: [:0]const u8,
    tunnel: backend_mod.StartTunnel,
) backend_mod.Error!i32 {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    self.turn_on_count += 1;
    std.debug.assert(tunnel.tun == null and tunnel.ifname == null);
    self.link = tunnel.passive.?.link;
    self.tun = tunnel.passive.?.tun;
    self.context = tunnel.passive.?.context;
    if (self.fail_turn_on_number == self.turn_on_count) return -1;
    return 7;
}

fn fakeTurnOff(ptr: ?*anyopaque, handle: i32) void {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    self.turn_off_count += 1;
    std.testing.expectEqual(@as(i32, 7), handle) catch unreachable;
}

fn fakeGetConfig(ptr: ?*anyopaque, allocator: std.mem.Allocator, _: i32) backend_mod.Error!?[]u8 {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    _ = self.counts.fetchAdd(1, .release);
    return try allocator.dupe(u8,
        \\rx_bytes=10
        \\tx_bytes=20
    );
}

fn fakeSetConfig(_: ?*anyopaque, _: std.mem.Allocator, _: i32, _: [:0]const u8) backend_mod.Error!i64 {
    @panic("v2 reconfigures through daemon reconnection");
}

fn fakeSocketDescriptors(_: ?*anyopaque, _: std.mem.Allocator, _: i32) backend_mod.Error![]io.SocketDescriptor {
    @panic("v2 must not access Go-owned sockets");
}

fn fakeBumpSockets(_: ?*anyopaque, _: i32, _: bool) void {
    @panic("v2 must not recreate Go-owned sockets");
}

fn fakeDisableRoaming(_: ?*anyopaque, _: i32) void {}
