// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const loop_helpers = @import("../net/looper_test_helpers.zig");

const source = @import("source");
const mock = source.mock;
const builtin = @import("builtin");

const wireguard_internal = source.wireguard_internal;
const adapter = wireguard_internal.adapter;
const backend_mod = wireguard_internal.backend;
const connection = source.wireguard_connection;
const conn = source.net_connection;
const core = source.core;
const io = source.net_io;
const sandbox = source.net_sandbox;
const tunnel_info = wireguard_internal.tunnel_info;
const uapi = wireguard_internal.uapi;

const api = core.api;
const AtomicBool = std.atomic.Value(bool);

const ConnectionContext = connection.ConnectionContext;
test "WireGuard connection builds UAPI configuration" {
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
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .fail_turn_on_number = 1 };
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    defer created.destroy();

    try std.testing.expectError(error.UnableToStart, startConnection(created));
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
}

test "WireGuard connection preserves allocator errors at the generic boundary" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .out_of_memory_turn_on_number = 1 };
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    defer created.destroy();

    try std.testing.expectError(error.OutOfMemory, startConnection(created));
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
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
        return error.WouldBlock;
    }
    fn write(_: *anyopaque, bytes: []const u8, offset: usize) io.Error!usize {
        return bytes.len - offset;
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

test "WireGuard data timer runs on its owner and cancels before stop" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),

        .options = .{ .min_data_count_interval = 1 },
    });
    defer created.destroy();

    try std.testing.expectEqual(@as(u32, 1), connection.testing.dataCountIntervalMs(created));
    try std.testing.expect(try startConnection(created));
    // Startup reports immediately, before the owner polls its first timer.
    try std.testing.expectEqual(@as(usize, 1), recorder.data_count_reports);
    try std.testing.expectEqual(@as(u64, 10), recorder.data_count.received);
    try std.testing.expectEqual(@as(u64, 20), recorder.data_count.sent);
    const initial_reports = recorder.data_count_reports;
    try std.testing.expect(try loop_helpers.poll(&environment.looper, 20));
    try std.testing.expectEqual(initial_reports + 1, recorder.data_count_reports);
    try std.testing.expectEqual(std.Thread.getCurrentId(), recorder.data_count_thread.?);
    // A fired timer schedules the next report on the same loop.
    try std.testing.expect(try loop_helpers.poll(&environment.looper, 20));
    try std.testing.expectEqual(initial_reports + 2, recorder.data_count_reports);
    created.stop();
    const stopped_reports = recorder.data_count_reports;
    try std.testing.expect(try loop_helpers.poll(&environment.looper, 5));
    try std.testing.expectEqual(stopped_reports, recorder.data_count_reports);

    try std.testing.expectEqual(@as(usize, 0), factory.configure_sockets_count);

    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.stopped_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
    try std.testing.expectEqual(@as(u64, 10), recorder.data_count.received);
    try std.testing.expectEqual(@as(u64, 20), recorder.data_count.sent);
}

test "WireGuard connection resolves hostname endpoints through sandbox resolver" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
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
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = resolver.resolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),

        .options = .{ .dns_timeout = 1234 },
    });
    defer created.destroy();

    try std.testing.expect(try startConnection(created));
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    created.networkChange(.{ .reachable = true });
    created.stop();

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
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    defer created.destroy();

    try std.testing.expect(try startConnection(created));
    created.betterPath();
    try std.testing.expectEqual(@as(usize, 1), recorder.rebind_count);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.set_config_count);
    const roaming_workarounds_before = fake_backend.disable_roaming_count;

    created.networkChange(.{ .reachable = true });

    try std.testing.expectEqual(@as(usize, 2), recorder.rebind_count);
    try std.testing.expectEqual(@as(usize, if (builtin.os.tag == .macos) 0 else 1), fake_backend.set_config_count);
    if (builtin.os.tag == .macos) {
        try std.testing.expect(fake_backend.last_set_config == null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, fake_backend.last_set_config.?, "endpoint=127.0.0.1:51820\n") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), factory.configure_sockets_count);
    try std.testing.expectEqual(
        roaming_workarounds_before + @as(usize, if (builtin.os.tag == .macos) 0 else 1),
        fake_backend.disable_roaming_count,
    );

    created.networkChange(.{ .reachable = false });
    created.betterPath();

    if (builtin.os.tag == .macos) {
        // Swift deliberately leaves wg-go alive on macOS regardless of the
        // reachability boolean and treats each event as a socket/path refresh.
        try std.testing.expectEqual(@as(usize, 0), fake_backend.turn_off_count);
        try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);

        created.networkChange(.{ .reachable = true });
        try std.testing.expectEqual(@as(usize, 0), fake_backend.bump_sockets_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);

        try std.testing.expectEqual(@as(usize, 5), recorder.rebind_count);
        try std.testing.expectEqual(@as(usize, 0), fake_backend.set_config_count);
        try std.testing.expectEqual(@as(usize, 0), fake_backend.disable_roaming_count);
        // The alternate policy still reapplies the workaround after live updates.
        adapter.testing.setNetworkChangeBehavior(connection.testing.adapter(created), .suspend_backend_when_offline);
        created.networkChange(.{ .reachable = true });
        try std.testing.expectEqual(@as(usize, 1), fake_backend.set_config_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.disable_roaming_count);

        created.stop();
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    } else {
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
        try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);

        created.networkChange(.{ .reachable = true });
        try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_on_count);

        created.stop();
        try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_off_count);
    }
    const rebinds_before = recorder.rebind_count;
    created.networkChange(.{ .reachable = true });
    created.betterPath();
    try std.testing.expectEqual(rebinds_before, recorder.rebind_count);
}

test "WireGuard takes ownership of link and TUN descriptors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),

        .options = .{ .min_data_count_interval = 2345 },
    });
    var destroyed = false;
    defer if (!destroyed) created.destroy();
    try std.testing.expectEqual(.link, created.daemon_io);

    var first_link = OwnedDescriptor{};
    var first_tun = OwnedDescriptor{};
    var second_link = OwnedDescriptor{};
    var second_tun = OwnedDescriptor{};
    try expectEstablished(try created.start(.{ .link = first_link.descriptor() }));
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try created.commit(first_tun.descriptor());
    try std.testing.expectEqual(@as(usize, 0), first_link.cleanups);
    try std.testing.expectEqual(@as(usize, 0), first_tun.cleanups);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.send_keepalives_count);

    try std.testing.expect(try created.rebind(.{ .link = second_link.descriptor() }, null));
    try std.testing.expectEqual(@as(usize, 1), fake_backend.send_keepalives_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), first_link.cleanups);
    try std.testing.expectEqual(@as(usize, 0), first_tun.cleanups);
    var third_link = OwnedDescriptor{};
    try std.testing.expect(try created.rebind(.{ .link = third_link.descriptor() }, second_tun.descriptor()));
    try std.testing.expectEqual(@as(usize, 1), second_link.cleanups);
    try std.testing.expectEqual(@as(usize, 1), first_tun.cleanups);

    // Unexpected EOF from an owned descriptor reaches daemon recovery once.
    const passive = &connection.testing.adapter(created).transport.passive.io;
    try std.testing.expect(!wireguard_internal.passive_io.PassiveIO.testing.receive(passive, .tun, &.{}, null, -1));
    // Worker delivery is immediate; the daemon sink is responsible for queuing recovery.
    try std.testing.expectEqual(@as(usize, 1), recorder.failure_count);
    try std.testing.expectEqual(@as(@TypeOf(recorder.failure.?.err_pair.code), .ioFailure), recorder.failure.?.err_pair.code);
    try std.testing.expectEqual(conn.Connection.Events.FailureDisposition.reconnect, recorder.failure.?.disposition);

    created.stop();
    created.stop();
    try std.testing.expectEqual(@as(usize, 1), third_link.cleanups);
    try std.testing.expectEqual(@as(usize, 1), second_link.cleanups);
    try std.testing.expectEqual(@as(usize, 1), second_tun.cleanups);

    var final_link = OwnedDescriptor{};
    var final_tun = OwnedDescriptor{};
    try expectEstablished(try created.start(.{ .link = final_link.descriptor() }));
    try created.commit(final_tun.descriptor());
    created.destroy();
    destroyed = true;
    try std.testing.expectEqual(@as(usize, 1), final_link.cleanups);
    try std.testing.expectEqual(@as(usize, 1), final_tun.cleanups);
    try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_on_count);
}

test "WireGuard connection retries temporary shutdown resume and re-resolves peers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .fail_turn_on_number = 2 };
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
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
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = resolver.resolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    defer created.destroy();
    connection.testing.setTemporaryShutdownRetryDelayMs(created, 1);

    try std.testing.expect(try startConnection(created));
    // Exercise suspend/resume semantics independently of the host running the
    // test; platform selection itself is just the production default policy.
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    var retained_tun = OwnedDescriptor{};
    try created.commit(retained_tun.descriptor());
    created.betterPath();
    created.networkChange(.{ .reachable = false });
    // The queued rebind must succeed even if an offline event overtakes it.
    var replacement_link = OwnedDescriptor{};
    try std.testing.expect(try created.rebind(.{ .link = replacement_link.descriptor() }, null));
    try std.testing.expectEqual(@as(usize, 0), fake_backend.send_keepalives_count);
    created.networkChange(.{ .reachable = true });
    try waitForRetry(&environment, &fake_backend, 3);

    try std.testing.expectEqual(@as(usize, 3), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 3), resolver.resolve_count);

    try std.testing.expectEqual(@as(usize, 0), factory.configure_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 2), recorder.rebind_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.stopped_count);
    try std.testing.expectEqual(@as(usize, 0), retained_tun.cleanups);

    created.stop();
    try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 1), retained_tun.cleanups);
}

test "WireGuard connection retries passive backend failure without terminal events" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{ .fail_turn_on_number = 2 };
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    defer created.destroy();
    connection.testing.setTemporaryShutdownRetryDelayMs(created, 1);

    try std.testing.expect(try startConnection(created));
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    created.networkChange(.{ .reachable = false });
    created.networkChange(.{ .reachable = true });

    // A transient backend failure must not emit terminal events.
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.stopped_count);

    try waitForRetry(&environment, &fake_backend, 3);

    try std.testing.expect(!connection.testing.adapter(created).isStopped());

    try std.testing.expectEqual(@as(usize, 3), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.stopped_count);
}

test "WireGuard connection cancels when a temporary shutdown retry cannot be scheduled" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    const context = ConnectionContext.init(fake_backend.backend());
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var tagged = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"127.0.0.1:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer tagged.deinit(allocator);
    const module = conn.activeConnectionModule(&tagged) orelse return error.TestUnexpectedResult;
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    const created = try connection.testing.createConnection(allocator, context.backend, .link, module, .{
        .profile = &tagged,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    defer created.destroy();

    try std.testing.expect(try startConnection(created));
    adapter.testing.setNetworkChangeBehavior(
        connection.testing.adapter(created),
        .suspend_backend_when_offline,
    );
    created.networkChange(.{ .reachable = false });
    connection.testing.simulateTemporaryShutdownRetrySchedulingFailure(created);

    try std.testing.expect(!connection.testing.adapter(created).isStopped());
    try std.testing.expectEqual(@as(usize, 1), recorder.failure_count);
    try std.testing.expectEqual(api.PartoutErrorCode.outOfMemory, recorder.failure.?.err_pair.code);
    try std.testing.expectEqual(conn.Connection.Events.FailureDisposition.cancel, recorder.failure.?.disposition);

    // Emulate the daemon finalizing the connection after receiving failure.
    created.stop();
    created.stop();
    try std.testing.expect(connection.testing.adapter(created).isStopped());
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);

    try std.testing.expectEqual(@as(usize, 1), recorder.stopped_count);
}

const FakeBackend = struct {
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

fn fakeGetConfig(_: ?*anyopaque, allocator: std.mem.Allocator, _: i32) backend_mod.Error!?[]u8 {
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
    resolve_error: ?sandbox.DNSResolver.Error = null,
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
    if (self.resolve_error) |err| return err;

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

const FakeSocketFactory = struct {
    configure_sockets_count: usize = 0,
    fail_configure_sockets: bool = false,

    fn interface(self: *FakeSocketFactory) sandbox.SocketFactory {
        return .{ .ptr = self, .vtable = &fake_socket_factory_vtable };
    }
};

const fake_socket_factory_vtable = blk: {
    var table = mock.noopSocketFactory().vtable.*;
    table.configure_sockets = fakeConfigureSockets;
    break :blk table;
};

fn fakeConfigureSockets(ptr: ?*anyopaque, descriptors: []const io.SocketDescriptor) sandbox.SocketFactory.Error!void {
    const self: *FakeSocketFactory = @ptrCast(@alignCast(ptr.?));
    self.configure_sockets_count += 1;
    if (self.fail_configure_sockets) return error.SocketConfiguration;
    if (!std.mem.eql(io.SocketDescriptor, &.{ 3, 4 }, descriptors)) return error.SocketConfiguration;
}

const EventRecorder = struct {
    established_count: usize = 0,
    rebind_count: usize = 0,
    tun_request_count: usize = 0,
    stopped_count: usize = 0,
    failure_count: usize = 0,
    failure: ?conn.Connection.Events.Failure = null,
    has_data_count: AtomicBool = AtomicBool.init(false),
    data_count_reports: usize = 0,
    data_count_thread: ?std.Thread.Id = null,
    data_count: api.DataCount = .{},

    fn events(self: *EventRecorder) conn.Connection.Events {
        return .{
            .ctx = self,
            .event = recordEvent,
        };
    }
};

fn recordEvent(ctx: *anyopaque, event: conn.Connection.Event) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    if (event == .needs_rebind and event.needs_rebind != null) {
        self.tun_request_count += 1;
        return;
    }
    switch (event) {
        .established => |success| recordEstablished(ctx, success),
        .needs_rebind => |info| recordNeedsRebind(ctx, info),
        .failed => |failure| recordFailed(ctx, failure),
        .stopped => recordStopped(ctx),
        .data_count => |count| recordDataCount(ctx, count),
        .set_env => {},
    }
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
    self.data_count_reports += 1;
    self.data_count_thread = std.Thread.getCurrentId();
    self.has_data_count.store(true, .release);
}

fn recordEstablished(ctx: *anyopaque, success: conn.Connection.Events.Success) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    std.testing.expectEqualStrings("WireGuard", success.info.profile.name) catch unreachable;
    self.established_count += 1;
}

fn recordNeedsRebind(ctx: *anyopaque, _: ?api.TunnelRemoteInfoWrapper) void {
    const self: *EventRecorder = @ptrCast(@alignCast(ctx));
    self.rebind_count += 1;
}

fn startConnection(created: conn.Connection) !bool {
    const socket = (try io.SocketWrapper.create(std.testing.allocator, null, .{ .ipv4 = true, .ipv6 = false })) orelse return error.SocketFailed;
    const link = socket.linkDescriptor();
    return (try consumeStartResult(try created.start(.{
        .link = link,
        .local_port = if (builtin.os.tag == .windows) 51820 else (try link.localAddress()).port,
    }))) == .established;
}

fn consumeStartResult(result: conn.Connection.StartResult) !std.meta.Tag(conn.Connection.StartResult) {
    switch (result) {
        .established => |success| {
            var owned = success;
            defer owned.info.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("33333333-3333-4333-8333-333333333333", &owned.info.original_module_id);
        },
        .started, .failed => {},
    }
    return std.meta.activeTag(result);
}

fn expectEstablished(result: conn.Connection.StartResult) !void {
    try std.testing.expectEqual(.established, try consumeStartResult(result));
}

test "WireGuard backend dispatches the passive startup payload separately" {
    if (builtin.os.tag == .windows and !source.winrt_enabled) return error.SkipZigTest;
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
    try std.testing.expect(backend_mod.goBackend().vtable.complete_io != null);

    const tun = try mock.createTun(std.testing.allocator);
    defer tun.destroy();
    try std.testing.expectError(error.TransportFailure, backend.turnOn(std.testing.allocator, "legacy", .{
        .tun = tun,
        .ifname = "test",
    }));
}

test "WireGuard adapter supports active startup and both reachability policies" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const Probe = struct {
        fn turnOn(raw: ?*anyopaque, alloc: std.mem.Allocator, settings: [:0]const u8, tunnel: backend_mod.StartTunnel) backend_mod.Error!i32 {
            const self: *FakeBackend = @ptrCast(@alignCast(raw.?));
            std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", tunnel.ifname) catch unreachable;
            self.turn_on_count += 1;
            if (self.last_settings) |value| alloc.free(value);
            self.last_settings = try alloc.dupe(u8, settings);
            return 7;
        }
    };
    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var vtable = fake_backend_vtable;
    vtable.turn_on = Probe.turnOn;
    var factory = FakeSocketFactory{};
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[],"activeModulesIds":[]}
    );
    defer profile.deinit(allocator);
    var configuration = try api.WireGuardConfiguration.parse(allocator,
        \\{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[]}
    );
    defer configuration.deinit(allocator);
    const tun = try io.TunWrapper.create(allocator, null);
    var sut = try adapter.WireGuardAdapter.init(profile.id, .{ .ptr = &fake_backend, .vtable = &vtable }, .none, mock.noopDNSResolver(), factory.interface(), &profile, &configuration, 1000);
    defer sut.deinit(allocator);

    sut.sendKeepalives(); // Safe before startup.
    var initial_info = (try sut.start(allocator, .{})).?;
    defer initial_info.deinit(allocator);
    try sut.commit(allocator, .{ .fd = -1, .io = .{ .tun = tun } });
    try std.testing.expect(sut.isStarted());
    try std.testing.expectEqual(@as(usize, 1), factory.configure_sockets_count);
    sut.sendKeepalives();
    try std.testing.expectEqual(@as(usize, 1), fake_backend.send_keepalives_count);

    adapter.testing.setNetworkChangeBehavior(&sut, .refresh_sockets);
    _ = sut.didUpdateReachable(allocator, false);
    try std.testing.expect(sut.isStarted());
    try std.testing.expectEqual(@as(usize, 1), fake_backend.bump_sockets_count);
    try std.testing.expectEqual(@as(usize, 2), factory.configure_sockets_count);

    adapter.testing.setNetworkChangeBehavior(&sut, .suspend_backend_when_offline);
    _ = sut.didUpdateReachable(allocator, false);
    try std.testing.expect(!sut.isStarted());
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_off_count);
    const result = sut.didUpdateReachable(allocator, true);
    try std.testing.expect(result == .needs_rebind);
    var info = result.needs_rebind.?;
    defer info.deinit(allocator);
    const replacement = try io.TunWrapper.create(allocator, null);
    var recorder = EventRecorder{};
    sut.prepareLinkRefresh(info, recorder.events());
    try sut.commit(allocator, .{ .fd = -1, .io = .{ .tun = replacement } });
    try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_on_count);
    _ = sut.didUpdateReachable(allocator, true);
    try std.testing.expectEqual(@as(usize, 2), fake_backend.bump_sockets_count);
    try std.testing.expectEqual(@as(usize, 4), factory.configure_sockets_count);

    sut.stop(allocator);
    try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_off_count);
}

test "WireGuard none mode resolves hostnames before establishment and resets uncommitted starts" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var vtable = fake_backend_vtable;
    vtable.turn_on = fakeActiveTurnOn;
    vtable.complete_io = null;
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var resolver = FakeResolver{
        .records = &.{.{ .address = "198.51.100.10", .is_ipv6 = false }},
        .resolve_error = error.ResolutionFailure,
    };
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[{"publicKey":"BJgXqaX9zQbZwBcvWMaYpxzXhIAmKxT4P7d9gklYxhw=","endpoint":"example.com:51820","allowedIPs":["0.0.0.0/0"]}]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer profile.deinit(allocator);
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    var context = ConnectionContext.init(.{ .ptr = &fake_backend, .vtable = &vtable });
    const created = try connection.createConnection(&context, allocator, conn.activeConnectionModule(&profile).?, .{
        .profile = &profile,
        .events = recorder.events(),
        .resolver = resolver.resolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    defer created.destroy();
    const remote = conn.RemoteDescriptor{};

    // Fail before the daemon sees establishment and applies routes or DNS.
    try std.testing.expectError(error.DNSResolutionFailure, created.start(remote));
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.turn_on_count);
    resolver.resolve_error = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, created.start(remote));
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);

    resolver.resolve_error = null;
    try expectEstablished(try created.start(remote));
    try std.testing.expectEqual(@as(usize, 3), resolver.resolve_count);
    try std.testing.expect(resolver.last_flags.contains(.allAddresses));
    try std.testing.expectEqual(@as(usize, 0), resolver.resolve_address_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.turn_on_count);
    // Repeated start while awaiting commit must preserve the prepared answers.
    try std.testing.expectEqual(.started, try consumeStartResult(try created.start(remote)));
    try std.testing.expectEqual(@as(usize, 3), resolver.resolve_count);

    // Cancellation before commit must discard cached answers, despite no Go handle.
    created.stop();
    resolver.records = &.{.{ .address = "198.51.100.20", .is_ipv6 = false }};
    try expectEstablished(try created.start(remote));
    try std.testing.expectEqual(@as(usize, 4), resolver.resolve_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);

    // Emulate settings making hostname DNS unreachable. Commit still succeeds,
    // while numeric mapping uses the current network.
    resolver.resolve_error = error.ResolutionFailure;
    resolver.mapped_address = "64:ff9b::c633:6414";
    var owned = OwnedDescriptor{};
    const tun = try io.TunWrapper.create(allocator, null);
    tun.test_descriptor = owned.descriptor();
    try created.commit(.{ .fd = -1, .io = .{ .tun = tun } });
    try std.testing.expectEqual(@as(usize, 4), resolver.resolve_count);
    try std.testing.expectEqual(@as(usize, 1), resolver.resolve_address_count);
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expect(std.mem.indexOf(u8, fake_backend.last_settings.?, "endpoint=[64:ff9b::c633:6414]:51820\n") != null);
    adapter.testing.setNetworkChangeBehavior(connection.testing.adapter(created), .suspend_backend_when_offline);
    created.networkChange(.{ .reachable = false });
    resolver.resolve_error = null;
    created.networkChange(.{ .reachable = true });
    try std.testing.expectEqual(@as(usize, 5), resolver.resolve_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.tun_request_count);
    // The daemon applies settings after the request; recommit must use cached DNS.
    resolver.resolve_error = error.ResolutionFailure;
    // Duplicate online notifications and retries must preserve the prepared answers.
    created.networkChange(.{ .reachable = true });
    try std.testing.expect(connection.testing.adapter(created).retryTemporaryShutdown(allocator) == .unchanged);
    try std.testing.expectEqual(@as(usize, 5), resolver.resolve_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.tun_request_count);
    var replacement_owned = OwnedDescriptor{};
    const replacement = try io.TunWrapper.create(allocator, null);
    replacement.test_descriptor = replacement_owned.descriptor();
    try std.testing.expect(try created.rebind(.{}, .{ .fd = -1, .io = .{ .tun = replacement } }));
    try std.testing.expectEqual(@as(usize, 5), resolver.resolve_count);
    try std.testing.expectEqual(@as(usize, 2), fake_backend.turn_on_count);
    created.stop();
    try std.testing.expectEqual(@as(usize, 1), owned.cleanups);
    try std.testing.expectEqual(@as(usize, 1), replacement_owned.cleanups);
}

test "WireGuard none mode owns committed TUN and refreshes backend sockets" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fake_backend = FakeBackend{};
    defer fake_backend.deinit(allocator);
    var vtable = fake_backend_vtable;
    vtable.turn_on = fakeActiveTurnOn;
    vtable.complete_io = null;
    var factory = FakeSocketFactory{};
    var recorder = EventRecorder{};
    var profile = try api.Profile.parse(allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"WireGuard","modules":[
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"SMy9zR0KUgqYqZ0pcyL3sJmJkmNkU8PA5mnr9nh3zUs=","addresses":["10.0.0.2/24"]},"peers":[]}}}
        \\],"activeModulesIds":["33333333-3333-4333-8333-333333333333"]}
    );
    defer profile.deinit(allocator);
    var environment: TimerEnvironment = undefined;
    try environment.init(allocator);
    defer environment.deinit();
    var context = ConnectionContext.init(.{ .ptr = &fake_backend, .vtable = &vtable });
    const created = try connection.createConnection(&context, allocator, conn.activeConnectionModule(&profile).?, .{
        .profile = &profile,
        .events = recorder.events(),
        .resolver = mock.noopDNSResolver(),
        .factory = factory.interface(),
        .writer = environment.writer(),
    });
    var destroyed = false;
    defer if (!destroyed) created.destroy();
    try std.testing.expectEqual(.none, created.daemon_io);
    connection.testing.setTemporaryShutdownRetryDelayMs(created, 1);
    const remote = conn.RemoteDescriptor{};
    try expectEstablished(try created.start(remote));
    try std.testing.expectEqual(@as(usize, 0), recorder.established_count);
    try std.testing.expectEqual(@as(usize, 0), fake_backend.turn_on_count);

    var owned = OwnedDescriptor{};
    const tun = try io.TunWrapper.create(allocator, null);
    tun.test_descriptor = owned.descriptor();
    try created.commit(.{ .fd = -1, .io = .{ .tun = tun } });
    try std.testing.expectEqual(@as(usize, 1), factory.configure_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), owned.cleanups);
    const sut = connection.testing.adapter(created);
    adapter.testing.setNetworkChangeBehavior(sut, .refresh_sockets);
    created.networkChange(.{ .reachable = true });
    created.betterPath();
    try std.testing.expectEqual(@as(usize, 1), fake_backend.bump_sockets_count);
    try std.testing.expectEqual(@as(usize, 2), factory.configure_sockets_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.rebind_count);

    adapter.testing.setNetworkChangeBehavior(sut, .suspend_backend_when_offline);
    created.networkChange(.{ .reachable = false });
    try std.testing.expectEqual(@as(usize, 0), owned.cleanups);
    created.networkChange(.{ .reachable = true });
    try std.testing.expectEqual(@as(usize, 1), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.tun_request_count);
    try std.testing.expectEqual(@as(usize, 0), owned.cleanups);
    // Repeated online events while commit is pending must not request another TUN.
    created.networkChange(.{ .reachable = true });
    try std.testing.expectEqual(@as(usize, 1), recorder.tun_request_count);
    // Recommit failures retain the previous TUN and release the rejected one.
    var failed_owned = OwnedDescriptor{};
    const failed_tun = try io.TunWrapper.create(allocator, null);
    failed_tun.test_descriptor = failed_owned.descriptor();
    factory.fail_configure_sockets = true;
    try std.testing.expect(try created.rebind(.{}, .{ .fd = -1, .io = .{ .tun = failed_tun } }));
    try std.testing.expectEqual(@as(usize, 1), failed_owned.cleanups);
    try std.testing.expectEqual(@as(usize, 0), owned.cleanups);
    factory.fail_configure_sockets = false;
    try std.testing.expect(try loop_helpers.poll(&environment.looper, 20));
    try std.testing.expectEqual(@as(usize, 2), recorder.tun_request_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.failure_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.stopped_count);
    var replacement_owned = OwnedDescriptor{};
    const replacement = try io.TunWrapper.create(allocator, null);
    replacement.test_descriptor = replacement_owned.descriptor();
    try std.testing.expect(try created.rebind(.{}, .{ .fd = -1, .io = .{ .tun = replacement } }));
    try std.testing.expectEqual(@as(usize, 1), owned.cleanups);
    try std.testing.expectEqual(@as(usize, 3), fake_backend.turn_on_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.rebind_count);
    created.stop();
    created.stop();
    try std.testing.expectEqual(@as(usize, 1), owned.cleanups);
    try std.testing.expectEqual(@as(usize, 1), recorder.stopped_count);
    try std.testing.expectEqual(@as(usize, 1), replacement_owned.cleanups);

    // Initial commit failures release the TUN and close the new backend.
    try expectEstablished(try created.start(remote));
    var rejected = OwnedDescriptor{};
    const rejected_tun = try io.TunWrapper.create(allocator, null);
    rejected_tun.test_descriptor = rejected.descriptor();
    factory.fail_configure_sockets = true;
    try std.testing.expectError(error.UnableToStart, created.commit(.{ .fd = -1, .io = .{ .tun = rejected_tun } }));
    try std.testing.expectEqual(@as(usize, 4), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 1), rejected.cleanups);
    created.stop();
    try std.testing.expectEqual(@as(usize, 1), rejected.cleanups);
    try std.testing.expectEqual(@as(usize, 2), recorder.stopped_count);

    factory.fail_configure_sockets = false;
    try expectEstablished(try created.start(remote));
    var final_owned = OwnedDescriptor{};
    const final_tun = try io.TunWrapper.create(allocator, null);
    final_tun.test_descriptor = final_owned.descriptor();
    try created.commit(.{ .fd = -1, .io = .{ .tun = final_tun } });
    created.networkChange(.{ .reachable = false });
    created.networkChange(.{ .reachable = true });
    // Destruction before recommit still owns and releases the retained TUN.
    created.destroy();
    destroyed = true;
    try std.testing.expectEqual(@as(usize, 5), fake_backend.turn_off_count);
    try std.testing.expectEqual(@as(usize, 1), final_owned.cleanups);
}

fn fakeActiveTurnOn(raw: ?*anyopaque, allocator: std.mem.Allocator, settings: [:0]const u8, start: backend_mod.StartTunnel) backend_mod.Error!i32 {
    const self: *FakeBackend = @ptrCast(@alignCast(raw.?));
    std.testing.expectEqualStrings("33333333-3333-4333-8333-333333333333", start.ifname) catch unreachable;
    self.turn_on_count += 1;
    if (self.last_settings) |value| allocator.free(value);
    self.last_settings = try allocator.dupe(u8, settings);
    if (self.fail_turn_on_number == self.turn_on_count) return -1;
    return 7;
}

fn fakeCompleteIO(_: usize, _: u32, _: i32) callconv(.c) void {}

const TimerEnvironment = struct {
    mux: loop_helpers.Mux,
    looper: source.net_looper.Looper,

    fn init(self: *@This(), allocator: std.mem.Allocator) !void {
        const mux = try loop_helpers.Mux.init();
        errdefer mux.deinit();
        self.* = .{
            .mux = mux,
            .looper = try source.net_looper.Looper.init(allocator, .{
                .mux = mux.handle,
            }),
        };
    }
    fn deinit(self: *@This()) void {
        self.looper.deinit();
        self.mux.deinit();
    }

    fn writer(self: *@This()) source.net.ConnectionWriter {
        return source.net.ConnectionWriter.init(&self.looper, &vtable);
    }
    fn write(raw: *anyopaque, packets: io.Packets, side: io.Side, destination: ?io.SocketAddress) (source.net.SubmissionError || error{MissingDestination})!void {
        const loop: *source.net_looper.Looper = @ptrCast(@alignCast(raw));
        loop.write(packets, side, destination) catch |err| switch (err) {
            error.SideNotAttached, error.InvalidBuffers => {},
            else => |failure| return failure,
        };
    }
    fn schedule(raw: *anyopaque, timer: *io.Timer, delay_ms: u64, task: io.TimedTask) source.net.SubmissionError!void {
        const loop: *source.net_looper.Looper = @ptrCast(@alignCast(raw));
        return loop.scheduleTimer(timer, delay_ms, task);
    }
    fn cancel(raw: *anyopaque, timer: *io.Timer) void {
        const loop: *source.net_looper.Looper = @ptrCast(@alignCast(raw));
        loop.cancelTimer(timer);
    }
    const vtable = source.net.ConnectionWriter.VTable{
        .write_packets = write,
        .schedule_timer = schedule,
        .cancel_timer = cancel,
    };
};

fn waitForRetry(environment: *TimerEnvironment, backend: *FakeBackend, expected: usize) !void {
    const deadline = core.monotonicNs() + 2 * std.time.ns_per_s;
    while (backend.turn_on_count < expected) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        try std.testing.expect(try loop_helpers.poll(&environment.looper, 10));
    }
}
