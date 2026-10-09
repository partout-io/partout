// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const wireguard_internal = @import("source").wireguard_internal;
const adapter = wireguard_internal.adapter_v2;
const backend_mod = wireguard_internal.backend;
const connection = @import("source").wireguard_connection_v2;
const conn = @import("source").net_connection;
const core = @import("source").core;
const io = @import("source").net_io;
const sandbox = @import("source").net_sandbox;
const tunnel_info = wireguard_internal.tunnel_info;
const uapi = wireguard_internal.uapi;

const api = core.api;
const AtomicBool = std.atomic.Value(bool);

fn waitUntil(value: *const AtomicBool) void {
    while (!value.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

const ConnectionContext = connection.ConnectionContext;
test "WireGuard connection builds UAPI configuration" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;
    var configuration = try api.WireGuardConfiguration.parse(allocator,
        \\{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"],"listenPort":51820},
        \\"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"],"keepAlive":25}]}
    );
    defer configuration.deinit(allocator);
    const configuration_text = try adapter.testing.buildUapiConfiguration(
        allocator,
        &configuration,
        mock.noopDNSResolver(),
    );
    defer allocator.free(configuration_text);

    try std.testing.expectEqual(@as(u8, 0), configuration_text[configuration_text.len]);
    try std.testing.expect(std.mem.indexOf(u8, configuration_text, "private_key=48ccbdcd1d0a520a98a99d297322f7b0998992636453c3c0e669ebf67877cd4b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration_text, "listen_port=51820\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration_text, "replace_peers=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration_text, "public_key=049817a9a5fdcd06d9c0172f58c698a71cd78480262b14f83fb77d824958c61c\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration_text, "endpoint=127.0.0.1:51820\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration_text, "persistent_keepalive_interval=25\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration_text, "allowed_ip=0.0.0.0/0\n") != null);
}

test "WireGuard connection builds tunnel info with IP and DNS modules" {
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24","fd00::2/128"],"dns":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]},"mtu":1420},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","allowedIPs":["0.0.0.0/0","::/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer profile.deinit(allocator);
    const conn_module = conn.activeConnectionModule(&profile) orelse return error.TestUnexpectedResult;
    const configuration = switch (conn_module.module.*) {
        .WireGuard => |wg| wg.configuration,
        else => unreachable,
    };

    // FIXME: #525, Make Configuration non-optional in OpenAPI and remove .IncompleteModule
    var info = try tunnel_info.TunnelRemoteInfoBuilder.init(
        allocator,
        &profile,
        conn_module.id(),
        &configuration.?,
    ).build();
    defer info.deinit(allocator);

    try std.testing.expectEqual(conn_module.id(), info.original_module_id);
    try std.testing.expectEqualStrings("127.0.0.1", info.address.?.raw);
    try std.testing.expect(info.profile.name.ptr != profile.name.ptr);

    const modules = info.modules orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), modules.len);
    const ip = switch (modules[0]) {
        .IP => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const dns = switch (modules[1]) {
        .DNS => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(core.isGeneratedId(ip.id[0..]));
    // FIXME: #525, Make Configuration non-optional in OpenAPI and remove .IncompleteModule
    try std.testing.expectEqual(configuration.?.interface.dns.?.id, dns.id);
    try std.testing.expectEqual(@as(?i32, 1420), ip.mtu);
    try std.testing.expectEqual(@as(u32, 1420), tunnel_info.TunnelRemoteInfoBuilder.effectiveMTU(info));
    try std.testing.expectEqualStrings("1.1.1.1", dns.servers[0].raw);

    const ipv4 = ip.ipv4 orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), ipv4.subnets.len);
    try std.testing.expectEqualStrings("10.0.0.2", ipv4.subnets[0].address.raw);
    try std.testing.expectEqual(@as(u8, 24), ipv4.subnets[0].prefix_length);
    try std.testing.expectEqual(@as(usize, 2), ipv4.included_routes.len);
    try std.testing.expectEqualStrings("10.0.0.0", ipv4.included_routes[0].destination.?.address.raw);
    try std.testing.expectEqualStrings("10.0.0.2", ipv4.included_routes[0].gateway.?.raw);
    try std.testing.expectEqualStrings("0.0.0.0", ipv4.included_routes[1].destination.?.address.raw);
    try std.testing.expect(ipv4.included_routes[1].gateway == null);

    const ipv6 = ip.ipv6 orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), ipv6.subnets.len);
    try std.testing.expectEqualStrings("fd00::2", ipv6.subnets[0].address.raw);
    try std.testing.expectEqual(@as(u8, 120), ipv6.subnets[0].prefix_length);
    try std.testing.expectEqual(@as(usize, 2), ipv6.included_routes.len);
    try std.testing.expectEqual(@as(u8, 128), ipv6.included_routes[0].destination.?.prefix_length);
    try std.testing.expectEqualStrings("fd00::2", ipv6.included_routes[0].gateway.?.raw);
    try std.testing.expectEqual(@as(u8, 0), ipv6.included_routes[1].destination.?.prefix_length);
    try std.testing.expect(ipv6.included_routes[1].gateway == null);
}

test "WireGuard connection folds active IP and VPN DNS routes into every peer" {
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
    const source_configuration = switch (profile.modules[0]) {
        .WireGuard => |wireguard| wireguard.configuration,
        else => unreachable,
    };

    // FIXME: #525, Make Configuration non-optional in OpenAPI and remove .IncompleteModule
    var merged = try connection.testing.configurationWithActiveModules(
        allocator,
        &source_configuration.?,
        &profile,
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

test "WireGuard connection parses runtime data count" {
    const data_count = uapi.parseRuntimeDataCount(
        \\public_key=abc
        \\rx_bytes=1234
        \\tx_bytes=5678
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1234), data_count.received);
    try std.testing.expectEqual(@as(u64, 5678), data_count.sent);
}

test "WireGuard connection erases backend activation errors at the generic boundary" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .fail_turn_on_number = 1 };
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = mock.noopDNSResolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
    });
    defer created.destroy();

    try std.testing.expectError(error.UnableToStart, startConnection(created, &environment.looper));
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
}

test "WireGuard connection preserves allocator errors at the generic boundary" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .out_of_memory_turn_on_number = 1 };
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = mock.noopDNSResolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
    });
    defer created.destroy();

    try std.testing.expectError(error.OutOfMemory, startConnection(created, &environment.looper));
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
}

test "WireGuard v2 takes ownership of link and TUN descriptors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = mock.noopDNSResolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
        .options = .{ .min_data_count_interval = 2345 },
    });
    var destroyed = false;
    defer if (!destroyed) created.destroy();
    try std.testing.expectEqual(.link, created.daemon_io);

    var first_link = OwnedDescriptor{};
    var first_tun = OwnedDescriptor{};
    var second_link = OwnedDescriptor{};
    var second_tun = OwnedDescriptor{};
    try std.testing.expect(try created.startV2(.{ .link = first_link.descriptor(), .looper = &environment.looper }));
    try std.testing.expectEqual(@as(usize, 1), recorder.established_count);
    created.commit(first_tun.descriptor());
    try std.testing.expectEqual(@as(usize, 0), first_link.cleanups);
    try std.testing.expectEqual(@as(usize, 0), first_tun.cleanups);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.send_keepalives_count);

    try std.testing.expect(try created.rebind(.{ .link = second_link.descriptor(), .looper = &environment.looper }));
    try std.testing.expectEqual(@as(usize, 1), fake_backend.send_keepalives_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), first_link.cleanups);
    try std.testing.expectEqual(@as(usize, 0), first_tun.cleanups);
    created.commit(second_tun.descriptor());
    try std.testing.expectEqual(@as(usize, 1), first_tun.cleanups);

    // Unexpected EOF from an owned descriptor reaches daemon recovery once.
    const transport = fake_backend.transport.?;
    const wg_c = wireguard_internal.passive_io.testing.abi;
    var buffer: [32]u8 = undefined;
    var packets = [_]wg_c.wg_read_packet{.{ .data = &buffer, .capacity = buffer.len }};
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(tunnel: backend_mod.StartTunnelPassive, batch: [*c]wg_c.wg_read_packet) void {
            std.testing.expectEqual(wg_c.WG_IO_OK, tunnel.tun.read.?(tunnel.context, batch, 1, 1)) catch unreachable;
        }
    }.run, .{ transport, &packets });
    worker.join();
    try std.testing.expectEqual(wg_c.WG_IO_CLOSED, transport.tun.read.?(transport.context, &packets, 1, 1));
    // Worker delivery is immediate; the daemon sink is responsible for queuing recovery.
    try std.testing.expectEqual(@as(usize, 1), recorder.failure_count);
    try std.testing.expectEqual(@as(@TypeOf(recorder.failure.?.err_pair.code), .ioFailure), recorder.failure.?.err_pair.code);
    try std.testing.expectEqual(conn.Connection.Events.FailureDisposition.reconnect, recorder.failure.?.disposition);

    created.stop(0, recorder.events());
    created.stop(0, recorder.events());
    try std.testing.expectEqual(@as(usize, 1), second_link.cleanups);
    try std.testing.expectEqual(@as(usize, 1), second_tun.cleanups);

    var final_link = OwnedDescriptor{};
    var final_tun = OwnedDescriptor{};
    try std.testing.expect(try created.startV2(.{ .link = final_link.descriptor(), .looper = &environment.looper }));
    created.commit(final_tun.descriptor());
    created.destroy();
    destroyed = true;
    try std.testing.expectEqual(@as(usize, 1), final_link.cleanups);
    try std.testing.expectEqual(@as(usize, 1), final_tun.cleanups);
    try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 0), controller.set_tunnel_settings_count);
}

const OwnedDescriptor = struct {
    cleanups: usize = 0,

    fn descriptor(self: *@This()) io.LinkDescriptor {
        return .{ .fd = -1, .io = .{ .mock = .{ .ptr = self, .vtable = &vtable } } };
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.cleanups += 1;
    }
    fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn reset(_: *anyopaque) io.Error!void {}
    fn read(_: *anyopaque, _: []u8) io.Error!?usize {
        return null;
    }
    fn write(_: *anyopaque, bytes: []const u8, offset: usize) io.Error!usize {
        return bytes.len - offset;
    }
    fn lastError(_: *anyopaque) c_int {
        return 0;
    }
    const vtable = @import("source").net_io_posix.POSIXInterface.Mock.VTable{
        .set_event_mask = mask,
        .reset_events = reset,
        .read = read,
        .write = write,
        .cleanup = cleanup,
        .last_error_code = lastError,
    };
};

test "WireGuard connection drains its running data timer before stopping" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = mock.noopDNSResolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
        .options = .{ .min_data_count_interval = 1 },
    });
    defer created.destroy();

    try std.testing.expectEqual(@as(u32, 1), connection.testing.dataCountIntervalMs(created));
    try std.testing.expect(try startConnection(created, &environment.looper));
    waitUntil(&recorder.has_data_count);
    fake_backend.block_get_config.store(true, .release);
    defer fake_backend.release_get_config.store(true, .release);
    waitUntil(&fake_backend.get_config_entered);
    const Stop = struct {
        fn run(value: conn.Connection, events: conn.Connection.Events, entered: *AtomicBool, finished: *AtomicBool) void {
            entered.store(true, .release);
            value.stop(1000, events);
            finished.store(true, .release);
        }
    };
    var stop_entered = AtomicBool.init(false);
    var stop_finished = AtomicBool.init(false);
    const worker = try std.Thread.spawn(.{}, Stop.run, .{ created, recorder.events(), &stop_entered, &stop_finished });
    defer worker.join();
    waitUntil(&stop_entered);
    const stopped_while_reading = stop_finished.load(.acquire);
    fake_backend.release_get_config.store(true, .release);
    waitUntil(&stop_finished);
    try std.testing.expect(!stopped_while_reading);

    try std.testing.expectEqual(@as(usize, 0), controller.set_tunnel_settings_count);
    try std.testing.expectEqual(@as(usize, 0), controller.configure_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), controller.clear_tunnel_settings_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.stopped_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
    try std.testing.expectEqual(@as(u64, 10), recorder.data_count.received);
    try std.testing.expectEqual(@as(u64, 20), recorder.data_count.sent);
}

test "WireGuard connection resolves hostname endpoints through sandbox resolver" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var resolver = FakeResolver{
        .records = &.{
            .{ .address = "fd00::1", .is_ipv6 = true },
            .{ .address = "198.51.100.10", .is_ipv6 = false },
        },
    };
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"example.com:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = resolver.resolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
        .options = .{ .dns_timeout = 1234 },
    });
    defer created.destroy();

    try std.testing.expect(try startConnection(created, &environment.looper));
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    created.networkChange(.{ .reachable = true }, recorder.events());
    created.stop(1000, recorder.events());

    try std.testing.expectEqual(@as(usize, 1), resolver.resolve_count);
    try std.testing.expect(resolver.last_flags.contains(.allAddresses));
    try std.testing.expectEqual(@as(u32, 1234), resolver.last_timeout_ms);
    try std.testing.expect(std.mem.indexOf(u8, fake_backend.last_settings.?, "endpoint=198.51.100.10:51820\n") != null);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.set_config_count);
    try std.testing.expect(std.mem.indexOf(u8, fake_backend.last_set_config.?, "endpoint=198.51.100.10:51820\n") != null);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.disable_roaming_count);
}

test "WireGuard DNS resolution stably prioritizes IPv4" {
    const allocator = std.testing.allocator;
    var resolver = FakeResolver{ .records = &.{
        .{ .address = "fd00::1", .is_ipv6 = true },
        .{ .address = "fd00::2", .is_ipv6 = true },
        .{ .address = "198.51.100.10", .is_ipv6 = false },
        .{ .address = "198.51.100.11", .is_ipv6 = false },
    } };
    var configuration = try api.WireGuardConfiguration.parse(allocator,
        \\{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":[]},"peers":[
        \\{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"example.com:51820","allowedIPs":[]}
        \\]}
    );
    defer configuration.deinit(allocator);

    const configuration_text = try adapter.testing.buildUapiConfiguration(
        allocator,
        &configuration,
        resolver.resolver(),
    );
    defer allocator.free(configuration_text);
    try std.testing.expect(std.mem.indexOf(
        u8,
        configuration_text,
        "endpoint=198.51.100.10:51820\n",
    ) != null);
}

test "WireGuard DNS resolution bypasses the resolver for numeric endpoints" {
    const allocator = std.testing.allocator;
    var resolver = FakeResolver{ .records = &.{
        .{ .address = "64:ff9b::c000:201", .is_ipv6 = true },
    } };
    var configuration = try api.WireGuardConfiguration.parse(allocator,
        \\{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":[]},"peers":[
        \\{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"77.160.28.16:51820","allowedIPs":[]},
        \\{"publicKey":"4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=","endpoint":"[2001:db8::1]:51820","allowedIPs":[]}
        \\]}
    );
    defer configuration.deinit(allocator);

    const uapi_configuration = try adapter.testing.buildUapiConfiguration(
        allocator,
        &configuration,
        resolver.resolver(),
    );
    defer allocator.free(uapi_configuration);

    try std.testing.expectEqual(@as(usize, 0), resolver.resolve_count);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "endpoint=77.160.28.16:51820\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "endpoint=[2001:db8::1]:51820\n") != null);
}

test "WireGuard DNS resolution accepts peers without endpoints" {
    const allocator = std.testing.allocator;
    var resolver = FakeResolver{ .records = &.{} };
    var configuration = try api.WireGuardConfiguration.parse(allocator,
        \\{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":[]},"peers":[
        \\{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","allowedIPs":["10.0.0.0/24"],"keepAlive":25}
        \\]}
    );
    defer configuration.deinit(allocator);

    const uapi_configuration = try adapter.testing.buildUapiConfiguration(
        allocator,
        &configuration,
        resolver.resolver(),
    );
    defer allocator.free(uapi_configuration);

    try std.testing.expectEqual(@as(usize, 0), resolver.resolve_count);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "endpoint=") == null);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "persistent_keepalive_interval=25\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "allowed_ip=10.0.0.0/24\n") != null);
}

test "WireGuard resolves every peer hostname" {
    const allocator = std.testing.allocator;
    var resolver = FakeResolver{ .records = &.{
        .{ .address = "198.51.100.10", .is_ipv6 = false },
    } };
    var configuration = try api.WireGuardConfiguration.parse(allocator,
        \\{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":[]},"peers":[
        \\{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"one.example:51820","allowedIPs":[]},
        \\{"publicKey":"4hBza7JtPKZFKwqtEmDR0iZyru1kqpQta/DRduMbHQw=","endpoint":"two.example:51821","allowedIPs":[]},
        \\{"publicKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","endpoint":"three.example:51822","allowedIPs":[]}
        \\]}
    );
    defer configuration.deinit(allocator);

    const uapi_configuration = try adapter.testing.buildUapiConfiguration(
        allocator,
        &configuration,
        resolver.resolver(),
    );
    defer allocator.free(uapi_configuration);

    try std.testing.expectEqual(@as(usize, 3), resolver.resolve_count);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "endpoint=198.51.100.10:51820\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "endpoint=198.51.100.10:51821\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, uapi_configuration, "endpoint=198.51.100.10:51822\n") != null);
}

test "WireGuard delegates current-network address mapping to DNSResolver" {
    const allocator = std.testing.allocator;
    var resolver = FakeResolver{
        .records = &.{},
        .mapped_address = "64:ff9b::4da0:1c10",
    };
    var configuration = try api.WireGuardConfiguration.parse(allocator,
        \\{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":[]},"peers":[
        \\{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"77.160.28.16:51820","allowedIPs":[]}
        \\]}
    );
    defer configuration.deinit(allocator);

    const configuration_text = try adapter.testing.buildUapiConfiguration(
        allocator,
        &configuration,
        resolver.resolver(),
    );
    defer allocator.free(configuration_text);

    try std.testing.expectEqual(@as(usize, 0), resolver.resolve_count);
    try std.testing.expectEqual(@as(usize, 1), resolver.resolve_address_count);
    try std.testing.expect(std.mem.indexOf(
        u8,
        configuration_text,
        "endpoint=[64:ff9b::4da0:1c10]:51820\n",
    ) != null);
}

test "WireGuard connection handles network monitor events" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = mock.noopDNSResolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
    });
    defer created.destroy();

    try std.testing.expect(try startConnection(created, &environment.looper));
    created.betterPath(recorder.events());
    try std.testing.expectEqual(@as(usize, 1), recorder.rebind_count);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.set_config_count);
    const roaming_workarounds_before = fake_backend.disable_roaming_count;

    created.networkChange(.{ .reachable = true }, recorder.events());

    try std.testing.expectEqual(@as(usize, 2), recorder.rebind_count);
    try std.testing.expectEqual(@as(usize, if (builtin.os.tag == .macos) 0 else 1), fake_backend.set_config_count);
    if (builtin.os.tag == .macos) {
        try std.testing.expect(fake_backend.last_set_config == null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, fake_backend.last_set_config.?, "endpoint=127.0.0.1:51820\n") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), controller.configure_sockets_count);
    try std.testing.expectEqual(
        roaming_workarounds_before + @as(usize, if (builtin.os.tag == .macos) 0 else 1),
        fake_backend.disable_roaming_count,
    );

    created.networkChange(.{ .reachable = false }, recorder.events());
    created.betterPath(recorder.events());

    if (builtin.os.tag == .macos) {
        // Swift deliberately leaves wg-go alive on macOS regardless of the
        // reachability boolean and treats each event as a socket/path refresh.
        try std.testing.expectEqual(@as(usize, 0), fake_backend.turn_off_count);
        try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);

        created.networkChange(.{ .reachable = true }, recorder.events());
        try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
        try std.testing.expectEqual(@as(usize, 0), controller.set_tunnel_settings_count);

        try std.testing.expectEqual(@as(usize, 5), recorder.rebind_count);
        try std.testing.expectEqual(@as(usize, 0), fake_backend.set_config_count);
        try std.testing.expectEqual(@as(usize, 0), fake_backend.disable_roaming_count);
        // The alternate policy still reapplies the workaround after live updates.
        adapter.testing.setNetworkChangeBehavior(connection.testing.adapter(created), .suspend_backend_when_offline);
        created.networkChange(.{ .reachable = true }, recorder.events());
        try std.testing.expectEqual(@as(usize, 1), fake_backend.set_config_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.disable_roaming_count);

        created.stop(1000, recorder.events());
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    } else {
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);

        created.networkChange(.{ .reachable = true }, recorder.events());
        try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_on_count);
        try std.testing.expectEqual(@as(usize, 0), controller.set_tunnel_settings_count);

        created.stop(1000, recorder.events());
        try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_off_count);
    }
    const rebinds_before = recorder.rebind_count;
    created.networkChange(.{ .reachable = true }, recorder.events());
    created.betterPath(recorder.events());
    try std.testing.expectEqual(rebinds_before, recorder.rebind_count);
}

test "WireGuard connection retries temporary shutdown resume and re-resolves peers" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .fail_turn_on_number = 2 };
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var resolver = FakeResolver{ .records = &.{
        .{ .address = "198.51.100.10", .is_ipv6 = false },
    } };
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"example.com:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = resolver.resolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
    });
    defer created.destroy();
    connection.testing.setTemporaryShutdownRetryDelayMs(created, 1);

    try std.testing.expect(try startConnection(created, &environment.looper));
    // Exercise suspend/resume semantics independently of the host running the
    // test; platform selection itself is just the production default policy.
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    var retained_tun = OwnedDescriptor{};
    created.commit(retained_tun.descriptor());
    created.betterPath(recorder.events());
    created.networkChange(.{ .reachable = false }, recorder.events());
    // The queued rebind must succeed even if an offline event overtakes it.
    var replacement_link = OwnedDescriptor{};
    try std.testing.expect(try created.rebind(.{ .link = replacement_link.descriptor(), .looper = &environment.looper }));
    try std.testing.expectEqual(@as(usize, 0), fake_backend.send_keepalives_count);
    created.networkChange(.{ .reachable = true }, recorder.events());
    connection.testing.waitForTemporaryShutdownRetry(created);

    try std.testing.expectEqual(@as(usize, 3), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 3), resolver.resolve_count);
    try std.testing.expectEqual(@as(usize, 0), controller.set_tunnel_settings_count);
    try std.testing.expectEqual(@as(usize, 0), controller.configure_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 2), recorder.rebind_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.stopped_count);
    try std.testing.expectEqual(@as(usize, 0), retained_tun.cleanups);

    created.stop(1000, recorder.events());
    try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 1), retained_tun.cleanups);
}

test "WireGuard connection retries passive backend failure without terminal events" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .fail_turn_on_number = 2 };
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = mock.noopDNSResolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
    });
    defer created.destroy();
    connection.testing.setTemporaryShutdownRetryDelayMs(created, 1);

    try std.testing.expect(try startConnection(created, &environment.looper));
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    created.networkChange(.{ .reachable = false }, recorder.events());
    created.networkChange(.{ .reachable = true }, recorder.events());

    // A transient backend failure must not emit terminal events.
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.stopped_count);

    connection.testing.waitForTemporaryShutdownRetry(created);

    try std.testing.expect(!connection.testing.adapter(created).isStopped());
    try std.testing.expectEqual(@as(usize, 0), controller.set_tunnel_settings_count);
    try std.testing.expectEqual(@as(usize, 3), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.stopped_count);
}

test "WireGuard connection cancels when a temporary shutdown retry cannot be scheduled" {
    const mock = @import("source").mock;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var context = ConnectionContext.init(fake_backend.backend());
    var controller = FakeController{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: mock.MockConnectionEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.createConnection(&context, allocator, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .controller = controller.controller(),
        .resolver = mock.noopDNSResolver(),
        .factory = mock.noopSocketFactory(),
        .looper = &environment.looper,
    });
    defer created.destroy();

    try std.testing.expect(try startConnection(created, &environment.looper));
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    created.networkChange(.{ .reachable = false }, recorder.events());
    connection.testing.simulateTemporaryShutdownRetrySchedulingFailure(
        created,
        recorder.events(),
    );

    try std.testing.expect(!connection.testing.adapter(created).isStopped());
    try std.testing.expectEqual(@as(usize, 1), recorder.failure_count);
    try std.testing.expectEqual(api.PartoutErrorCode.unhandled, recorder.failure.?.err_pair.code);
    try std.testing.expectEqual(conn.Connection.Events.FailureDisposition.cancel, recorder.failure.?.disposition);
    try std.testing.expectEqual(@as(usize, 0), controller.clear_tunnel_settings_count);

    // Emulate the daemon finalizing the connection after receiving failure.
    created.stop(0, recorder.events());
    created.stop(0, recorder.events());
    try std.testing.expect(connection.testing.adapter(created).isStopped());
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 0), controller.clear_tunnel_settings_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.stopped_count);
}

const FakeBackend = struct {
    block_get_config: AtomicBool = AtomicBool.init(false),
    get_config_entered: AtomicBool = AtomicBool.init(false),
    release_get_config: AtomicBool = AtomicBool.init(false),
    turn_on_count: usize = 0,
    turn_off_count: usize = 0,
    set_config_count: usize = 0,
    bump_sockets_count: usize = 0,
    send_keepalives_count: usize = 0,
    disable_roaming_count: usize = 0,
    fail_turn_on_number: ?usize = null,
    out_of_memory_turn_on_number: ?usize = null,
    transport: ?backend_mod.StartTunnelPassive = null,
    last_settings: ?[]u8 = null,
    last_set_config: ?[]u8 = null,

    fn deinit(self: *FakeBackend, allocator: std.mem.Allocator) void {
        if (self.last_settings) |value| allocator.free(value);
        if (self.last_set_config) |value| allocator.free(value);
    }

    fn backend(self: *FakeBackend) backend_mod.Backend {
        return .{
            .ptr = self,
            .vtable = &fake_backend_vtable,
        };
    }
};

const fake_backend_vtable = backend_mod.Backend.VTable{
    .turn_on_passive = fakeTurnOn,
    .complete_io = fakeCompleteIO,
    .turn_off = fakeTurnOff,
    .get_config = fakeGetConfig,
    .set_config = fakeSetConfig,
    .socket_descriptors = fakeSocketDescriptors,
    .bump_sockets = fakeBumpSockets,
    .send_keepalives = fakeSendKeepalives,
    .disable_roaming = fakeDisableRoaming,
};

fn fakeTurnOn(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    settings: [:0]const u8,
    tunnel: backend_mod.StartTunnelPassive,
) backend_mod.Error!i32 {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    std.testing.expect(tunnel.link.read != null and tunnel.link.write != null and tunnel.tun.read != null and tunnel.tun.write != null) catch unreachable;
    self.transport = tunnel;
    self.turn_on_count += 1;
    if (self.out_of_memory_turn_on_number == self.turn_on_count)
        return error.OutOfMemory;
    if (self.last_settings) |value| allocator.free(value);
    self.last_settings = try allocator.dupe(u8, settings);
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
    if (self.block_get_config.load(.acquire)) {
        self.get_config_entered.store(true, .release);
        waitUntil(&self.release_get_config);
    }
    return try allocator.dupe(u8,
        \\rx_bytes=10
        \\tx_bytes=20
    );
}

fn fakeSetConfig(ptr: ?*anyopaque, allocator: std.mem.Allocator, _: i32, settings: [:0]const u8) backend_mod.Error!i64 {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    self.set_config_count += 1;
    if (self.last_set_config) |value| allocator.free(value);
    self.last_set_config = try allocator.dupe(u8, settings);
    return 0;
}

fn fakeSocketDescriptors(_: ?*anyopaque, allocator: std.mem.Allocator, _: i32) backend_mod.Error![]io.SocketDescriptor {
    return try allocator.dupe(io.SocketDescriptor, &.{ 3, 4 });
}

fn fakeBumpSockets(ptr: ?*anyopaque, _: i32, _: bool) void {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    self.bump_sockets_count += 1;
}

fn fakeSendKeepalives(ptr: ?*anyopaque, handle: i32) void {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    std.testing.expectEqual(@as(i32, 7), handle) catch unreachable;
    self.send_keepalives_count += 1;
}

fn fakeDisableRoaming(ptr: ?*anyopaque, _: i32) void {
    const self: *FakeBackend = @ptrCast(@alignCast(ptr.?));
    self.disable_roaming_count += 1;
}

const FakeResolver = struct {
    const Record = struct {
        address: []const u8,
        is_ipv6: bool,
    };

    records: []const Record,
    mapped_address: ?[]const u8 = null,
    resolve_count: usize = 0,
    resolve_address_count: usize = 0,
    last_hostname: ?[]const u8 = null,
    last_flags: std.EnumSet(sandbox.DNSResolver.Flag) = std.EnumSet(sandbox.DNSResolver.Flag).initEmpty(),
    last_timeout_ms: u32 = 0,

    fn resolver(self: *FakeResolver) sandbox.DNSResolver {
        return .{
            .ptr = self,
            .resolve_block = fakeResolve,
            .resolve_address_block = fakeResolveAddress,
        };
    }
};

fn fakeResolve(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    hostname: []const u8,
    flags: std.EnumSet(sandbox.DNSResolver.Flag),
    _: ?io.ReachabilityInfo,
    timeout_ms: u32,
) sandbox.DNSResolver.Error![]sandbox.DNSRecord {
    const self: *FakeResolver = @ptrCast(@alignCast(ptr.?));
    self.resolve_count += 1;
    self.last_hostname = hostname;
    self.last_flags = flags;
    self.last_timeout_ms = timeout_ms;

    const records = try allocator.alloc(sandbox.DNSRecord, self.records.len);
    errdefer allocator.free(records);
    for (self.records, 0..) |record, index| {
        records[index] = .{
            .address = try allocator.dupe(u8, record.address),
            .is_ipv6 = record.is_ipv6,
        };
    }
    return records;
}

fn fakeResolveAddress(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    address: []const u8,
    _: ?io.ReachabilityInfo,
    _: u32,
) sandbox.DNSResolver.Error![]u8 {
    const self: *FakeResolver = @ptrCast(@alignCast(ptr.?));
    self.resolve_address_count += 1;
    return allocator.dupe(u8, self.mapped_address orelse address);
}

const FakeController = struct {
    set_tunnel_settings_count: usize = 0,
    fail_set_tunnel_settings_number: ?usize = null,
    configure_sockets_count: usize = 0,
    clear_tunnel_settings_count: usize = 0,

    fn controller(self: *FakeController) sandbox.TunnelController {
        return .{
            .ptr = self,
            .vtable = &fake_controller_vtable,
        };
    }
};

const fake_controller_vtable = sandbox.TunnelController.VTable{
    .set_tunnel_settings = fakeSetTunnelSettings,
    .configure_sockets = fakeConfigureSockets,
    .report_snapshot = fakeReportSnapshot,
    .set_environment_value = fakeSetEnvironmentValue,
    .clear_tunnel_settings = fakeClearTunnelSettings,
    .set_reasserting = fakeSetReasserting,
    .cancel_tunnel_connection = fakeCancelTunnelConnection,
};

fn fakeSetTunnelSettings(ptr: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) sandbox.TunnelController.Error!*io.TunWrapper {
    const self: *FakeController = @ptrCast(@alignCast(ptr.?));
    self.set_tunnel_settings_count += 1;
    if (self.fail_set_tunnel_settings_number == self.set_tunnel_settings_count)
        return error.TunNotAvailable;
    if (info.original_module_id.len == 0) return error.InvalidProfile;
    return io.TunWrapper.create(std.testing.allocator, null);
}

fn fakeConfigureSockets(ptr: ?*anyopaque, descriptors: []const io.SocketDescriptor) sandbox.TunnelController.Error!void {
    const self: *FakeController = @ptrCast(@alignCast(ptr.?));
    self.configure_sockets_count += 1;
    if (!std.mem.eql(io.SocketDescriptor, &.{ 3, 4 }, descriptors)) return error.SocketConfiguration;
}

fn fakeReportSnapshot(_: ?*anyopaque, _: api.TunnelSnapshot) void {}

fn fakeSetEnvironmentValue(_: ?*anyopaque, _: []const u8, _: ?[]const u8) void {}

fn fakeClearTunnelSettings(ptr: ?*anyopaque, _: bool) void {
    const self: *FakeController = @ptrCast(@alignCast(ptr.?));
    self.clear_tunnel_settings_count += 1;
}

fn fakeSetReasserting(_: ?*anyopaque, _: bool) void {}

fn fakeCancelTunnelConnection(_: ?*anyopaque, _: ?api.PartoutErrorPair) void {}

const EventRecorder = struct {
    established_count: usize = 0,
    rebind_count: usize = 0,
    stopped_count: usize = 0,
    failure_count: usize = 0,
    failure: ?conn.Connection.Events.Failure = null,
    has_data_count: AtomicBool = AtomicBool.init(false),
    data_count: api.DataCount = .{},

    fn events(self: *EventRecorder) conn.Connection.Events {
        return .{
            .ctx = self,
            .established = recordEstablished,
            .needs_rebind = recordNeedsRebind,
            .failed = recordFailed,
            .stopped = recordStopped,
            .status = recordStatus,
            .last_error = recordLastError,
            .data_count = recordDataCount,
            .cancel = recordCancel,
        };
    }
};

fn recordStatus(_: *anyopaque, _: api.ConnectionStatus) void {
    @panic("WireGuard v2 emitted legacy status");
}

fn recordLastError(_: *anyopaque, _: api.PartoutErrorPair) void {
    @panic("WireGuard v2 emitted legacy last_error");
}

fn recordFailed(ctx: *anyopaque, failure: conn.Connection.Events.Failure) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    self.failure_count += 1;
    self.failure = failure;
}

fn recordStopped(ctx: *anyopaque) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    self.stopped_count += 1;
}

fn recordDataCount(ctx: *anyopaque, data_count: api.DataCount) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    self.data_count = data_count;
    self.has_data_count.store(true, .release);
}

fn recordCancel(_: *anyopaque, _: ?api.PartoutErrorPair) void {
    @panic("WireGuard v2 emitted legacy cancel");
}

fn recordEstablished(ctx: *anyopaque, success: conn.Connection.Events.Success) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    std.testing.expectEqualStrings("WireGuard", success.info.profile.name) catch unreachable;
    self.established_count += 1;
}

fn recordNeedsRebind(ctx: *anyopaque) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    self.rebind_count += 1;
}

fn startConnection(created: conn.Connection, looper: *@import("source").net.Looper) !bool {
    const socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.SocketFailed;
    const link = socket.linkDescriptor();
    return created.startV2(.{
        .link = link,
        .local_port = if (builtin.os.tag == .windows) 51820 else (try link.localAddress()).port,
        .looper = looper,
    });
}

test "WireGuard backend dispatches the passive startup payload separately" {
    const Probe = struct {
        fn turnOn(raw: ?*anyopaque, _: std.mem.Allocator, settings: [:0]const u8, tunnel: backend_mod.StartTunnelPassive) backend_mod.Error!i32 {
            const called: *bool = @ptrCast(@alignCast(raw.?));
            if (tunnel.context != raw.? or tunnel.link.local_port != 51820 or tunnel.tun.mtu != 1420 or
                !std.mem.eql(u8, settings, "passive")) return error.TransportFailure;
            called.* = true;
            return 7;
        }
    };
    var called = false;
    var vtable = fake_backend_vtable;
    vtable.turn_on_passive = Probe.turnOn;
    const backend = backend_mod.Backend{ .ptr = &called, .vtable = &vtable };
    const tunnel = backend_mod.StartTunnelPassive{
        .link = .{ .local_port = 51820, .read = null, .write = null },
        .tun = .{ .mtu = 1420, .read = null, .write = null },
        .context = &called,
    };
    try std.testing.expectEqual(@as(i32, 7), try backend.turnOnPassive(std.testing.allocator, "passive", tunnel));
    try std.testing.expect(called);
    try std.testing.expectError(error.TransportFailure, backend_mod.goBackend().turnOnPassive(std.testing.allocator, "passive", tunnel));

    const tun = try io.TunWrapper.create(std.testing.allocator, null);
    defer tun.destroy();
    try std.testing.expectError(error.TransportFailure, backend_mod.goPassiveBackend().turnOn(std.testing.allocator, "legacy", .{
        .tun = tun,
        .ifname = "test",
    }));
}

fn fakeCompleteIO(_: usize, _: u32, _: i32) callconv(.c) void {}
