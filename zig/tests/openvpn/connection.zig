// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const connection = source.openvpn_connection;
const mock = source.mock;
const net = source.net;

test "OpenVPN connection declarations are semantically analyzed" {
    std.testing.refAllDecls(connection);
}

test "OpenVPN connection borrows the daemon looper" {
    const Callbacks = struct {
        fn onFinish(_: ?*anyopaque, _: ?net.Looper.Failure) void {}

        fn barrier(_: ?*anyopaque) !void {}
    };

    const allocator = std.testing.allocator;
    var looper = try net.Looper.init(allocator, .{
        .on_finish = .{ .callback = Callbacks.onFinish },
    });
    defer looper.deinit();
    try looper.start();
    var looper_started = true;
    defer if (looper_started) looper.stop() catch {};

    const endpoint = api.ExtendedEndpoint.init(
        "192.0.2.1",
        .init(.udp, 1194),
    ).?;
    const remotes = [_]api.ExtendedEndpoint{endpoint};
    const module_id: api.UUID = "11111111-1111-4111-8111-111111111111".*;
    const profile_id: api.UUID = "22222222-2222-4222-8222-222222222222".*;
    const modules = [_]api.TaggedModule{.{ .OpenVPN = .{
        .id = module_id,
        .configuration = .{ .remotes = &remotes },
    } }};
    const active_ids = [_]api.UUID{module_id};
    const profile = api.Profile{
        .id = profile_id,
        .name = "OpenVPN",
        .modules = &modules,
        .active_modules_ids = &active_ids,
    };
    var context = connection.ConnectionContext.init(
        source.c_crypto.pp_crypto_fnt_mock(),
    );
    const created = try connection.createConnection(
        &context,
        allocator,
        .{ .module = &modules[0] },
        .{
            .profile = &profile,
            .controller = mock.noopTunnelController(),
            .resolver = mock.noopDNSResolver(),
            .factory = mock.noopSocketFactory(),
            .monitor = mock.alwaysReachableMonitor(),
            .looper = &looper,
            .cache_dir = "/tmp",
        },
    );
    created.deinit(allocator);

    try looper.perform(void, null, Callbacks.barrier);
    try looper.stop();
    looper_started = false;
}

test "active default IP modules add OpenVPN routing policies" {
    const allocator = std.testing.allocator;
    const ip_id: api.UUID = "11111111-1111-4111-8111-111111111111".*;
    const openvpn_id: api.UUID = "22222222-2222-4222-8222-222222222222".*;
    const included = [_]api.Route{.{}};
    const modules = [_]api.TaggedModule{
        .{ .IP = .{
            .id = ip_id,
            .ipv4 = .{
                .subnets = &.{},
                .included_routes = &included,
                .excluded_routes = &.{},
            },
        } },
        .{ .OpenVPN = .{
            .id = openvpn_id,
            .configuration = .{},
        } },
    };
    const active_ids = [_]api.UUID{ ip_id, openvpn_id };
    const profile = api.Profile{
        .id = "33333333-3333-4333-8333-333333333333".*,
        .name = "OpenVPN",
        .modules = &modules,
        .active_modules_ids = &active_ids,
    };
    var configured = try connection.testing.configurationWithActiveModules(
        allocator,
        &.{},
        &profile,
    );
    defer configured.deinit(allocator);

    const policies = configured.routing_policies orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(
        api.OpenVPNRoutingPolicy,
        &.{.IPv4},
        policies,
    );
}
