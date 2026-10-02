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
    tun_reads: std.atomic.Value(usize) = .init(0),
    link_reads: std.atomic.Value(usize) = .init(0),
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
    fn receiveTun(_: i32, packet: [*c]const u8, size: u32) callconv(.c) i32 {
        std.debug.assert(size == 4 and packet[0] == 0x45);
        _ = current.tun_reads.fetchAdd(1, .release);
        return 0;
    }
    fn receiveLink(_: i32, packet: [*c]const u8, size: u32, endpoint: [*c]const c.wg_endpoint) callconv(.c) i32 {
        std.debug.assert(size == 3 and packet[0] == 1 and endpoint.*.port != 0);
        _ = current.link_reads.fetchAdd(1, .release);
        return 0;
    }
    fn setTunnel(raw: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) source.net_sandbox.TunnelController.Error!io.TunWrapper {
        const ctrl: *source.mock.MockTunnelController = @ptrCast(@alignCast(raw.?));
        _ = try ctrl.interface().setTunnelSettings(info);
        var tun = io.TunWrapper.init(null);
        tun.test_descriptor = .{ .fd = current.fd, .io = .{ .mock = .{ .ptr = current, .vtable = &vtable } } };
        return tun;
    }
    fn datagram(_: ?*anyopaque, allocator: std.mem.Allocator, port: u16) source.net_sandbox.SocketFactory.Error!*io.SocketWrapper {
        return try io.SocketWrapper.create(allocator, null, .{ .port = port }) orelse error.LinkNotActive;
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
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
    }
    var probe = Probe{ .fd = fds[0] };
    Probe.current = &probe;
    var fake = FakeBackend{ .fail_turn_on_number = 1 };
    var backend_table = fake_backend_vtable;
    backend_table.receive_datagram = Probe.receiveLink;
    backend_table.receive_tun_packet = Probe.receiveTun;
    var ctx = source.wireguard_connection_v2.ConnectionContext.init(.{ .ptr = &fake, .vtable = &backend_table });
    var registry = try source.net_connection.ConnectionRegistry.init(allocator, &.{.{ .ptr = &ctx, .vtable = &source.wireguard_exports.connection_v2_vtable }});
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var controller_table = controller.interface().vtable.*;
    controller_table.set_tunnel_settings = Probe.setTunnel;
    var monitor = mock.MockNetworkMonitor{};
    var factory = mock.noopSocketFactory();
    var factory_table = factory.vtable.*;
    factory_table.create_datagram = Probe.datagram;
    factory.vtable = &factory_table;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer profile.deinit(allocator);
    const sut = try source.net_daemon_v2.Daemon.create(allocator, &profile, .{
        .objects = .{ .registry = &registry, .controller = .{ .ptr = &controller, .vtable = &controller_table }, .resolver = mock.noopDNSResolver(), .factory = factory, .monitor = monitor.interface() },
        .options = .{ .connection_options = .{ .min_data_count_interval = 10 }, .reconnection_delay_ms = 60_000 },
    });
    defer sut.destroy();
    try sut.start();
    defer sut.stop();
    const owner = sut.implementation.connection;
    try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expect(!owner.looper.isLinkAttached());
    try owner.actor.perform(void, .evaluateConnection);
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expect(owner.tunnel != null and owner.looper.isTunAttached() and owner.looper.isLinkAttached());
    try std.testing.expectEqual(@as(usize, 2), fake.turn_on_count);
    try std.testing.expect(fake.link != null and fake.tun != null);
    try wait(&fake.counts, 2);
    _ = libc.write(fds[1], &.{ 0x45, 1, 2, 3 }, 4);
    try wait(&probe.tun_reads, 1);
    var packet = [_]u8{ 0x60, 4, 5, 6 };
    try std.testing.expectEqual(@as(i32, 0), fake.tun.?.write.?(fake.context, &packet, packet.len));
    packet[0] = 0;
    try wait(&probe.writes, 1);
    const peer = (try io.SocketWrapper.create(allocator, null, .{})).?;
    defer peer.destroy();
    var address = std.mem.zeroes(io.SocketAddress);
    address.family = 4;
    address.port = fake.link.?.local_port;
    address.address[0] = 127;
    address.address[3] = 1;
    _ = try peer.sendTo(&.{ 1, 2, 3 }, address);
    try wait(&probe.link_reads, 1);
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
