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
    writes: std.atomic.Value(usize) = .init(0),
    sockets: std.atomic.Value(usize) = .init(0),
    fail_socket_create: std.atomic.Value(bool) = .init(false),
    path_monitor: ?*source.mock.MockNetworkMonitor = null,
    cleaned: usize = 0,
    borrowed_read_ptr: ?[*]u8 = null,
    borrowed_write_ptr: ?[*]const u8 = null,
    block_writes: std.atomic.Value(bool) = .init(false),
    blocked_writes: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(usize) = .init(0),
    var current: *Probe = undefined;
    fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn reset(_: *anyopaque) io.Error!void {}
    fn read(raw: *anyopaque, buf: []u8) io.Error!?usize {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (self.borrowed_read_ptr) |ptr| std.debug.assert(ptr == buf.ptr);
        const size = libc.read(self.fd, buf.ptr, buf.len);
        if (size < 0) return error.WouldBlock;
        return @intCast(size);
    }
    fn write(raw: *anyopaque, bytes: []const u8, offset: usize) io.Error!usize {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (self.borrowed_write_ptr) |ptr| std.debug.assert(ptr == bytes.ptr);
        if (self.block_writes.load(.acquire)) {
            _ = self.blocked_writes.fetchAdd(1, .release);
            return error.Backpressure;
        }
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
    fn completeIO(request: usize, count: u32, status: i32) callconv(.c) void {
        std.debug.assert(request > 0 and request <= 7);
        const bit = @as(usize, 1) << @intCast(request - 1);
        if (status == c.WG_IO_CLOSED) {
            std.debug.assert(count == 0);
            _ = current.cancelled.fetchOr(bit, .release);
        } else {
            std.debug.assert(status == c.WG_IO_OK and count == 1);
        }
        const previous = current.completed.fetchOr(bit, .release);
        std.debug.assert(previous & bit == 0);
    }
    fn setTunnel(raw: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) source.net_sandbox.TunnelController.Error!io.TunWrapper {
        const ctrl: *source.mock.MockTunnelController = @ptrCast(@alignCast(raw.?));
        _ = try ctrl.interface().setTunnelSettings(info);
        // Apple can report the new path while applying our tunnel settings.
        if (current.path_monitor) |monitor| monitor.setReachable(true);
        var tun = io.TunWrapper.init(null);
        tun.test_descriptor = .{ .fd = current.fd, .io = .{ .mock = .{ .ptr = current, .vtable = &vtable } } };
        return tun;
    }
    fn createSocket(_: ?*anyopaque, allocator: std.mem.Allocator, endpoint: ?api.ExtendedEndpoint, _: ?io.ReachabilityInfo, _: c_int, port: u16) source.net_sandbox.SocketFactory.Error!io.LinkDescriptor {
        std.debug.assert(endpoint == null);
        std.debug.assert(port == current.requested_port);
        if (current.fail_socket_create.swap(false, .acq_rel)) return error.LinkNotActive;
        const socket = try io.SocketWrapper.create(allocator, endpoint, .{ .port = port }) orelse return error.LinkNotActive;
        _ = current.sockets.fetchAdd(1, .release);
        return socket.linkDescriptor();
    }
};
fn wait(counter: *const std.atomic.Value(usize), target: usize) !void {
    for (0..1000) |_| {
        if (counter.load(.acquire) >= target) return;
        _ = libc.usleep(1000);
    }
    return error.Timeout;
}

fn waitStatus(sut: *source.net_daemon_v2.Daemon, status: api.ConnectionStatus) !void {
    for (0..3000) |_| {
        try std.testing.expectError(error.AlreadyStarted, sut.start());
        if (sut.snapshot_publisher.environment.connection_status == status) return;
        _ = libc.usleep(1000);
    }
    return error.Timeout;
}

fn waitRefresh(sut: *source.net_daemon_v2.Daemon, fake: *FakeBackend, count: usize) !void {
    try wait(&fake.refreshes, count);
    // Statistics resume only after the endpoint worker has joined.
    try wait(&fake.counts, fake.counts.load(.acquire) + 1);
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
}

test "WireGuard v2 daemon owns link and TUN across retry, path changes and termination" {
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
    var dns = RefreshDNS{};
    var ctx = source.wireguard_connection_v2.ConnectionContext.init(.{ .ptr = &fake, .vtable = &fake_backend_vtable });
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
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"],"mtu":1400},"peers":[{"publicKey":"CQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","endpoint":"vpn.example:51820","allowedIPs":[]}]}}},
        \\{"type":"IP","value":{"id":"44444444-4444-4444-8444-444444444444","mtu":1380}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333","44444444-4444-4444-8444-444444444444"]}
    );
    defer profile.deinit(allocator);
    const module = @constCast(api.findActiveConnectionModule(&profile).?);
    module.WireGuard.configuration.?.interface.listen_port = requested_port;
    const sut = try source.net_daemon_v2.Daemon.create(allocator, &profile, .{
        .objects = .{ .registry = &registry, .controller = .{ .ptr = &controller, .vtable = &controller_table }, .resolver = dns.interface(), .factory = factory, .monitor = monitor.interface() },
        .options = .{ .connection_options = .{ .min_data_count_interval = 10 }, .reconnection_delay_ms = 60_000 },
    });
    defer sut.destroy();
    try sut.start();
    defer sut.stop();
    const owner = sut.implementation.connection;
    try std.testing.expect(owner.endpoint_resolver == null);
    try waitStatus(sut, .disconnected);
    try std.testing.expect(!owner.looper.isLinkAttached());
    try owner.actor.perform(void, .evaluateConnection);
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try waitStatus(sut, .connected);
    try std.testing.expect(owner.tunnel != null and owner.looper.isTunAttached() and owner.looper.isLinkAttached());
    try std.testing.expectEqual(@as(usize, 2), fake.turn_on_count);
    try std.testing.expect(fake.link != null and fake.tun != null);
    try std.testing.expectEqual(requested_port, fake.link.?.local_port);
    try std.testing.expectEqual(@as(u32, 1380), fake.tun.?.mtu);
    try wait(&fake.counts, 2);
    try std.testing.expectEqual(@as(usize, 2), dns.queries.load(.acquire));
    const cleared_before_refresh = controller.clear_tunnel_settings_count;
    // DNS is unavailable during transport replacement, but numeric bases must
    // survive and still be remapped onto the new network's DNS64 prefix.
    dns.unavailable.store(true, .release);
    dns.dns64.store(true, .release);
    // A same/worse path can remain reachable and never emit betterPath.
    // Duplicate notifications during refresh must coalesce into one update.
    monitor.setReachable(true);
    monitor.setReachable(true);
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try waitRefresh(sut, &fake, 1);
    try std.testing.expectEqual(@as(usize, 0), probe.cleaned);
    try std.testing.expect(owner.looper.isTunAttached() and owner.looper.isLinkAttached());
    try std.testing.expectEqual(@as(usize, 1), controller.set_tunnel_settings_count);
    try std.testing.expectEqual(cleared_before_refresh, controller.clear_tunnel_settings_count);
    try std.testing.expectEqual(@as(usize, 2), fake.turn_on_count);
    try std.testing.expectEqual(@as(usize, 0), fake.turn_off_count);
    try std.testing.expectEqual(@as(usize, 2), dns.queries.load(.acquire));
    try std.testing.expect(fake.refreshed_dns64.load(.acquire));
    // A route/settings-induced reachable notification must not reapply the
    // settings and generate an endless connect/disconnect feedback loop.
    for (2..5) |count| {
        if (count == 4) monitor.onBetterPath() else monitor.setReachable(true);
        try waitRefresh(sut, &fake, count);
        try std.testing.expectEqual(@as(usize, 1), controller.set_tunnel_settings_count);
        try std.testing.expectEqual(cleared_before_refresh, controller.clear_tunnel_settings_count);
        try std.testing.expectEqual(@as(usize, 0), probe.cleaned);
    }
    dns.unavailable.store(false, .release);
    monitor.setReachable(false);
    try waitRefresh(sut, &fake, 5);
    monitor.setReachable(true);
    try waitRefresh(sut, &fake, 6);
    try std.testing.expectEqual(@as(usize, 2), fake.turn_on_count);
    try std.testing.expectEqual(@as(usize, 0), fake.turn_off_count);
    try owner.looper.stop();
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try waitStatus(sut, .connected);
    // A genuinely new backend must perform a fresh hostname lookup.
    try std.testing.expectEqual(@as(usize, 3), dns.queries.load(.acquire));
    // Endpoint refresh failure must close the retained backend; the next
    // attempt starts a fresh device rather than retrying a half-updated one.
    fake.fail_set_config.store(true, .release);
    monitor.setReachable(true);
    try wait(&fake.set_config_failures, 1);
    try waitStatus(sut, .disconnected);
    try std.testing.expectEqual(@as(usize, 2), fake.turn_off_count);
    // Interrupt the next activation while its worker awaits a borrowed read.
    // Shutdown must cancel the read before joining that worker and closing Go.
    fake.await_startup_cancellation.store(true, .release);
    try owner.actor.perform(void, .resumeGate);
    try wait(&fake.startup_waiting, 1);
    monitor.onBetterPath();
    try waitStatus(sut, .disconnected);
    try std.testing.expectEqual(@as(usize, 64), probe.cancelled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), fake.turn_off_count);
    try owner.actor.perform(void, .resumeGate);
    try waitStatus(sut, .connected);
    try std.testing.expectEqual(@as(usize, 5), fake.turn_on_count);
    // A failed socket replacement must release the retained TUN/backend and
    // enter the ordinary retry path rather than leaving a paused connection.
    probe.fail_socket_create.store(true, .release);
    monitor.setReachable(true);
    try waitStatus(sut, .disconnected);
    try std.testing.expect(!owner.looper.isLinkAttached() and !owner.looper.isTunAttached());
    try std.testing.expectEqual(@as(usize, 4), fake.turn_off_count);
    try owner.actor.perform(void, .resumeGate);
    try waitStatus(sut, .connected);
    try std.testing.expectEqual(@as(usize, 6), fake.turn_on_count);
    // Explicit stop can overtake a queued link refresh.
    monitor.setReachable(true);
    sut.stop();
    try std.testing.expectEqual(@as(usize, 5), fake.turn_off_count);
    try std.testing.expectEqual(@as(usize, 4), probe.cleaned);
}

test "WireGuard v2 borrows payloads and cancels I/O before joining backend" {
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
    var fake = FakeBackend{};
    var ctx = source.wireguard_connection_v2.ConnectionContext.init(.{ .ptr = &fake, .vtable = &fake_backend_vtable });
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
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try waitStatus(sut, .connected);
    var tun_bytes: [64]u8 = undefined;
    var link_bytes: [64]u8 = undefined;
    var tun_input = [_]c.wg_read_packet{.{ .data = &tun_bytes, .capacity = tun_bytes.len }};
    var link_input = [_]c.wg_read_packet{.{ .data = &link_bytes, .capacity = link_bytes.len }};
    probe.borrowed_read_ptr = &tun_bytes;
    try std.testing.expectEqual(@as(i32, 0), fake.tun.?.read.?(fake.context, &tun_input, 1, 1));
    try std.testing.expectEqual(@as(i32, 0), fake.link.?.read.?(fake.context, &link_input, 1, 2));
    _ = libc.write(fds[1], &.{ 0x45, 1, 2, 3 }, 4);
    const peer = (try io.SocketWrapper.create(allocator, null, .{})).?;
    defer peer.destroy();
    const local = io.SocketAddress{ .family = 4, .port = fake.link.?.local_port, .address = .{ 127, 0, 0, 1 } ++ .{0} ** 12 };
    // Repeated oversized unauthenticated datagrams must not detach the link,
    // complete the Go loan with an error, or starve the following valid packet.
    const oversized = [_]u8{0} ** 1800;
    for (0..8) |_| _ = try peer.sendTo(&oversized, local);
    _ = try peer.sendTo(&.{ 1, 2, 3 }, local);
    try wait(&probe.completed, 3);
    try std.testing.expectEqualSlices(u8, &.{ 0x45, 1, 2, 3 }, tun_bytes[0..tun_input[0].size]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, link_bytes[0..link_input[0].size]);
    try std.testing.expectEqual((try peer.localAddress()).port, link_input[0].source.port);
    const output_bytes = [_]u8{ 0x60, 4, 5, 6 };
    const output = [_]c.wg_packet{.{ .data = &output_bytes, .size = output_bytes.len }};
    probe.borrowed_write_ptr = &output_bytes;
    // Reject an invalid suffix before borrowing or writing any valid prefix.
    const invalid_output = [_]c.wg_packet{ output[0], .{ .data = null, .size = 4 } };
    try std.testing.expectEqual(@as(i32, c.WG_IO_INVALID), fake.tun.?.write.?(fake.context, &invalid_output, 2, 3));
    try std.testing.expectEqual(@as(usize, 0), probe.writes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), probe.completed.load(.acquire));
    try std.testing.expectEqual(@as(i32, 0), fake.tun.?.write.?(fake.context, &output, 1, 3));
    const destination = c.wg_endpoint{ .family = 4, .port = (try peer.localAddress()).port, .address = .{ 127, 0, 0, 1 } ++ .{0} ** 12 };
    try std.testing.expectEqual(@as(i32, 0), fake.link.?.write.?(fake.context, &output, 1, &destination, 4));
    try wait(&probe.completed, 15);
    var received: [64]u8 = undefined;
    var sender: io.SocketAddress = undefined;
    try std.testing.expectEqual(@as(usize, 4), try peer.receiveFrom(&received, &sender));
    try std.testing.expectEqualSlices(u8, &output_bytes, received[0..4]);
    // Empty read attempts retain the loan. Outstanding loans and queued writes
    // must complete exactly once before fakeTurnOff can join the Go workers.
    try std.testing.expectEqual(@as(i32, 0), fake.tun.?.read.?(fake.context, &tun_input, 1, 5));
    try std.testing.expectEqual(@as(i32, 0), fake.link.?.read.?(fake.context, &link_input, 1, 6));
    probe.block_writes.store(true, .release);
    try std.testing.expectEqual(@as(i32, 0), fake.tun.?.write.?(fake.context, &output, 1, 7));
    try wait(&probe.blocked_writes, 1);
    fake.required_completions = 127;
    sut.stop();
    try std.testing.expectEqual(@as(usize, 127), probe.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 112), probe.cancelled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake.turn_off_count);
}

test "WireGuard v2 real Go workers retain TUN across settings-induced path updates" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (c.pp_wg_init() != 0) return error.SkipZigTest;
    // Zig stack unwinding cannot traverse Go callback stacks on Darwin.
    const allocator = std.heap.c_allocator;
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
    var ctx = source.wireguard_connection_v2.ConnectionContext.init(backend_mod.goPassiveBackend());
    var registry = try source.net_connection.ConnectionRegistry.init(allocator, &.{.{ .ptr = &ctx, .vtable = &source.wireguard_exports.connection_v2_vtable }});
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var controller_table = controller.interface().vtable.*;
    controller_table.set_tunnel_settings = Probe.setTunnel;
    var monitor = mock.MockNetworkMonitor{};
    probe.path_monitor = &monitor;
    var factory = mock.noopSocketFactory();
    var factory_table = factory.vtable.*;
    factory_table.create = Probe.createSocket;
    factory.vtable = &factory_table;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"CQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","endpoint":"127.0.0.1:51821","allowedIPs":["10.0.0.1/32"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer profile.deinit(allocator);
    const module = @constCast(api.findActiveConnectionModule(&profile).?);
    module.WireGuard.configuration.?.interface.listen_port = requested_port;
    const peer = (try io.SocketWrapper.create(allocator, null, .{})).?;
    defer peer.destroy();
    @constCast(module.WireGuard.configuration.?.peers)[0].endpoint.?.port = (try peer.localAddress()).port;
    @constCast(module.WireGuard.configuration.?.peers)[0].keep_alive = 25;
    const sut = try source.net_daemon_v2.Daemon.create(allocator, &profile, .{
        .objects = .{ .registry = &registry, .controller = .{ .ptr = &controller, .vtable = &controller_table }, .resolver = mock.noopDNSResolver(), .factory = factory, .monitor = monitor.interface() },
        .options = .{ .connection_options = .{ .min_data_count_interval = 10 }, .reconnection_delay_ms = 60_000 },
    });
    defer sut.destroy();
    try sut.start();
    defer sut.stop();
    try std.testing.expectError(error.AlreadyStarted, sut.start());
    try waitStatus(sut, .connected);
    // Trigger a handshake through a native TUN read into a Go-supplied buffer.
    // The encrypted output crosses back through the borrowed write completion.
    var ip = [_]u8{0} ** 20;
    ip[0] = 0x45;
    ip[3] = 20;
    ip[12] = 10;
    ip[15] = 2;
    ip[16] = 10;
    ip[19] = 1;
    for (0..2) |iteration| {
        _ = libc.write(fds[1], &ip, ip.len);
        var received: [512]u8 = undefined;
        var sender: io.SocketAddress = undefined;
        var size: ?usize = null;
        for (0..7000) |_| {
            size = peer.receiveFrom(&received, &sender) catch |err| {
                if (err != error.WouldBlock) return err;
                _ = libc.usleep(1000);
                continue;
            };
            break;
        }
        try std.testing.expectEqual(@as(?usize, 148), size);
        try std.testing.expectEqual(@as(u8, 1), received[0]);
        // Exercise the borrowed UDP receive path as well. An unauthenticated
        // packet is consumed and dropped by WireGuard without killing reads.
        _ = try peer.sendTo(&.{ 1, 2, 3 }, sender);
        if (iteration == 0) {
            // Applying settings itself emitted a reachable update. Wait for
            // its replacement socket before exercising the retained Go device.
            try wait(&probe.sockets, 2);
            try std.testing.expectError(error.AlreadyStarted, sut.start());
            try waitStatus(sut, .connected);
            try std.testing.expectEqual(@as(usize, 1), controller.set_tunnel_settings_count);
            try std.testing.expectEqual(@as(usize, 0), probe.cleaned);
        }
    }
    // The workers now await more read buffers/data. Finish must cancel their
    // requests before joining Go, including the unexpected-looper-exit path.
    try sut.implementation.connection.looper.stop();
    sut.stop();
}

test "WireGuard v2 MTU follows host module precedence" {
    const before = "11111111-1111-4111-8111-111111111111".*;
    const wg = "33333333-3333-4333-8333-333333333333".*;
    const after = "44444444-4444-4444-8444-444444444444".*;
    const inactive = "55555555-5555-4555-8555-555555555555".*;
    var modules = [_]api.TaggedModule{
        .{ .IP = .{ .id = before, .mtu = 1600 } },
        .{ .WireGuard = .{ .id = wg } },
        .{ .IP = .{ .id = after, .mtu = 1380 } },
        .{ .IP = .{ .id = inactive, .mtu = 1280 } },
    };
    var info = api.TunnelRemoteInfoWrapper{
        .profile = .{ .modules = &modules, .active_modules_ids = &.{ before, wg, after } },
        .original_module_id = wg,
        .modules = &.{.{ .IP = .{ .mtu = 1400 } }},
    };
    const effectiveMTU = source.wireguard_connection_v2.testing.effectiveMTU;
    try std.testing.expectEqual(@as(u32, 1380), effectiveMTU(info));
    // Only positive MTUs override. An inactive module never wins.
    for ([_]?i32{ null, 0, -1 }) |mtu| {
        modules[2].IP.mtu = mtu;
        try std.testing.expectEqual(@as(u32, 1400), effectiveMTU(info));
    }
    // An unspecified generated MTU preserves an earlier active override.
    info.modules = &.{.{ .IP = .{ .mtu = 0 } }};
    try std.testing.expectEqual(@as(u32, 1600), effectiveMTU(info));
    info.profile.active_modules_ids = &.{wg};
    try std.testing.expectEqual(@as(u32, 1420), effectiveMTU(info));
}

test "WireGuard v2 preserves active routes and allocation ownership" {
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":[]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","allowedIPs":["192.168.0.0/16"]},{"publicKey":"4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=","allowedIPs":[]}]}}},
        \\{"type":"DNS","value":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1","2606:4700:4700::1111","resolver.example"],"routesThroughVPN":true}},
        \\{"type":"DNS","value":{"id":"22222222-2222-4222-8222-222222222222","protocolType":{"type":"cleartext"},"servers":["9.9.9.9"],"routesThroughVPN":false}},
        \\{"type":"IP","value":{"id":"44444444-4444-4444-8444-444444444444","ipv4":{"subnets":[],"includedRoutes":[{"destination":"10.20.0.0/16"},{}],"excludedRoutes":[]},"ipv6":{"subnets":[],"includedRoutes":[{"destination":"fd00::/64"},{}],"excludedRoutes":[]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333","11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222","44444444-4444-4444-8444-444444444444"]}
    );
    defer profile.deinit(allocator);
    try std.testing.checkAllAllocationFailures(allocator, checkActiveRoutes, .{&profile});
}

fn checkActiveRoutes(allocator: std.mem.Allocator, profile: *const api.Profile) !void {
    const source_configuration = switch (profile.modules[0]) {
        .WireGuard => |wireguard| wireguard.configuration,
        else => unreachable,
    };

    var merged = try source.wireguard_connection_v2.testing.configurationWithActiveModules(
        allocator,
        &source_configuration.?,
        profile,
    );
    defer merged.deinit(allocator);

    const expected_extras = [_][]const u8{
        "10.20.0.0/16",
        "0.0.0.0/0",
        "fd00::/64",
        "::/0",
        "1.1.1.1/32",
        "2606:4700:4700::1111/128",
    };
    try std.testing.expectEqual(@as(usize, 2), merged.peers.len);
    for (merged.peers, 0..) |peer, peer_index| {
        const original_count: usize = if (peer_index == 0) 1 else 0;
        try std.testing.expectEqual(original_count + expected_extras.len, peer.allowed_ips.len);
        if (peer_index == 0) {
            const original = try peer.allowed_ips[0].rawAlloc(allocator);
            defer allocator.free(original);
            try std.testing.expectEqualStrings("192.168.0.0/16", original);
        }
        for (expected_extras, 0..) |expected, index| {
            const raw = try peer.allowed_ips[original_count + index].rawAlloc(allocator);
            defer allocator.free(raw);
            try std.testing.expectEqualStrings(expected, raw);
        }
    }
}

const RefreshDNS = struct {
    queries: std.atomic.Value(usize) = .init(0),
    unavailable: std.atomic.Value(bool) = .init(false),
    dns64: std.atomic.Value(bool) = .init(false),

    fn interface(self: *RefreshDNS) source.net_sandbox.DNSResolver {
        return .{ .ptr = self, .resolve_block = resolve, .resolve_address_block = remap };
    }
    fn resolve(raw: ?*anyopaque, allocator: std.mem.Allocator, hostname: []const u8, _: std.EnumSet(source.net_sandbox.DNSResolver.Flag), _: ?io.ReachabilityInfo, _: u32) source.net_sandbox.DNSResolver.Error![]source.net_sandbox.DNSRecord {
        const self: *RefreshDNS = @ptrCast(@alignCast(raw.?));
        std.debug.assert(std.mem.eql(u8, hostname, "vpn.example"));
        _ = self.queries.fetchAdd(1, .release);
        if (self.unavailable.load(.acquire)) return error.ResolutionFailure;
        const address = try allocator.dupe(u8, "192.0.2.1");
        errdefer allocator.free(address);
        const records = try allocator.alloc(source.net_sandbox.DNSRecord, 1);
        records[0] = .init(address, false);
        return records;
    }
    fn remap(raw: ?*anyopaque, allocator: std.mem.Allocator, address: []const u8, _: ?io.ReachabilityInfo, _: u32) source.net_sandbox.DNSResolver.Error![]u8 {
        const self: *RefreshDNS = @ptrCast(@alignCast(raw.?));
        std.debug.assert(std.mem.eql(u8, address, "192.0.2.1"));
        return allocator.dupe(u8, if (self.dns64.load(.acquire)) "64:ff9b::c000:201" else address);
    }
};

const FakeBackend = struct {
    link: ?@import("wireguard_c").wg_passive_link = null,
    tun: ?@import("wireguard_c").wg_passive_tun = null,
    context: ?*anyopaque = null,
    counts: std.atomic.Value(usize) = .init(0),
    refreshes: std.atomic.Value(usize) = .init(0),
    refreshed_dns64: std.atomic.Value(bool) = .init(false),
    turn_on_count: usize = 0,
    turn_off_count: usize = 0,
    fail_turn_on_number: ?usize = null,
    required_completions: ?usize = null,
    fail_set_config: std.atomic.Value(bool) = .init(false),
    set_config_failures: std.atomic.Value(usize) = .init(0),
    await_startup_cancellation: std.atomic.Value(bool) = .init(false),
    startup_waiting: std.atomic.Value(usize) = .init(0),
};

const fake_backend_vtable = backend_mod.Backend.VTable{
    .complete_io = Probe.completeIO,
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
    if (self.await_startup_cancellation.swap(false, .acq_rel)) {
        var bytes: [64]u8 = undefined;
        var packets = [_]c.wg_read_packet{.{ .data = &bytes, .capacity = bytes.len }};
        std.debug.assert(self.link.?.read.?(self.context, &packets, 1, 7) == c.WG_IO_OK);
        self.startup_waiting.store(1, .release);
        while (Probe.current.cancelled.load(.acquire) & 64 == 0) _ = libc.usleep(1000);
    }
    return 7;
}

fn fakeTurnOff(ptr: ?*anyopaque, handle: i32) void {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    if (self.required_completions) |mask| std.debug.assert(Probe.current.completed.load(.acquire) == mask);
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

fn fakeSetConfig(ptr: ?*anyopaque, _: std.mem.Allocator, _: i32, settings: [:0]const u8) backend_mod.Error!i64 {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    defer _ = self.refreshes.fetchAdd(1, .release);
    std.debug.assert(std.mem.indexOf(u8, settings, "replace_peers") == null);
    self.refreshed_dns64.store(std.mem.indexOf(u8, settings, "endpoint=[64:ff9b::c000:201]:51820") != null, .release);
    if (self.fail_set_config.swap(false, .acq_rel)) {
        _ = self.set_config_failures.fetchAdd(1, .release);
        return -1;
    }
    return 0;
}

fn fakeSocketDescriptors(_: ?*anyopaque, _: std.mem.Allocator, _: i32) backend_mod.Error![]io.SocketDescriptor {
    @panic("v2 must not access Go-owned sockets");
}

fn fakeBumpSockets(_: ?*anyopaque, _: i32, _: bool) void {
    @panic("v2 must not recreate Go-owned sockets");
}

fn fakeDisableRoaming(_: ?*anyopaque, _: i32) void {}
