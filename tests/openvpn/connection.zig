// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const core = source.core;
const api = core.api;
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
    var context = connection.ConnectionContext{
        .session_options = .{ .backend = .mock },
    };
    var controller = mock.MockTunnelController{};
    const executor = try mock.MockSerializedExecutor.create(allocator);
    defer executor.destroy();
    const created = try connection.createConnection(
        &context,
        allocator,
        .{ .module = &modules[0] },
        .{
            .profile = &profile,
            .controller = controller.interface(),
            .resolver = mock.noopDNSResolver(),
            .factory = mock.noopSocketFactory(),
            .looper = &looper,
            .cache_dir = "/tmp",
            .serialized_executor = executor.interface(),
        },
    );
    created.destroy();

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

test "OpenVPN connection accepts only valid status transitions" {
    const statusCanChange = connection.testing.statusCanChange;
    try std.testing.expect(statusCanChange(.disconnected, .connecting));
    try std.testing.expect(!statusCanChange(.disconnected, .connected));
    try std.testing.expect(statusCanChange(.connecting, .connected));
    try std.testing.expect(statusCanChange(.connecting, .disconnecting));
    try std.testing.expect(statusCanChange(.connecting, .disconnected));
    try std.testing.expect(statusCanChange(.connected, .disconnecting));
    try std.testing.expect(statusCanChange(.connected, .disconnected));
    try std.testing.expect(statusCanChange(.disconnecting, .disconnected));
    try std.testing.expect(!statusCanChange(.connected, .connecting));
    try std.testing.expect(!statusCanChange(.connected, .connected));
}

test "OpenVPN connection distinguishes recoverable session failures" {
    const isRecoverable = connection.testing.isRecoverableSessionError;
    try std.testing.expect(isRecoverable(error.Timeout));
    try std.testing.expect(isRecoverable(error.ConnectionFailure));
    try std.testing.expect(isRecoverable(error.BadCredentialsWithLocalOptions));
    try std.testing.expect(isRecoverable(error.ServerShutdown));
    try std.testing.expect(isRecoverable(error.NetworkChanged));
    try std.testing.expect(isRecoverable(error.Reconnect));
    try std.testing.expect(!isRecoverable(error.BadCredentials));
    try std.testing.expect(!isRecoverable(error.CryptoFailure));
    try std.testing.expect(!isRecoverable(error.NoRouting));
}

test "OpenVPN connection maps tunnel setup failures to public codes" {
    const codeForError = connection.testing.codeForTunnelError;
    try std.testing.expectEqual(
        api.PartoutErrorCode.tunNotAvailable,
        codeForError(error.TunNotAvailable),
    );
    try std.testing.expectEqual(
        api.PartoutErrorCode.socketConfiguration,
        codeForError(error.SocketConfiguration),
    );
    try std.testing.expectEqual(
        api.PartoutErrorCode.networkChanged,
        codeForError(error.NetworkChanged),
    );
    try std.testing.expectEqual(
        api.PartoutErrorCode.timeout,
        codeForError(error.Timeout),
    );
    try std.testing.expectEqual(
        api.PartoutErrorCode.crypto,
        codeForError(error.CryptoFailure),
    );
    try std.testing.expectEqual(
        api.PartoutErrorCode.unhandled,
        codeForError(error.Unexpected),
    );
}
