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

test "OpenVPN connection failure dispositions" {
    const isRecoverableError = connection.testing.isRecoverableError;

    try std.testing.expect(!isRecoverableError(error.BadCredentials));
    try std.testing.expect(!isRecoverableError(error.CompressionMismatch));
    try std.testing.expect(!isRecoverableError(error.InvalidPushReply));
    try std.testing.expect(!isRecoverableError(error.NoRouting));
    try std.testing.expect(!isRecoverableError(error.TLSFailure));
    try std.testing.expect(!isRecoverableError(error.UnsupportedAlgorithm));
    try std.testing.expect(!isRecoverableError(error.UnsupportedCompression));
    try std.testing.expect(!isRecoverableError(error.UnsupportedCryptoBackend));

    try std.testing.expect(isRecoverableError(error.BadCredentialsWithLocalOptions));
    try std.testing.expect(isRecoverableError(error.LinkFailure));
    try std.testing.expect(isRecoverableError(error.NetworkChanged));
    try std.testing.expect(isRecoverableError(error.OutOfMemory));
    try std.testing.expect(isRecoverableError(error.ServerShutdown));
    try std.testing.expect(isRecoverableError(error.TunNotAvailable));
}

test "OpenVPN connection errors map to legacy public codes" {
    const codeForError = connection.testing.codeForError;
    const cases = .{
        .{ error.BadCredentials, api.PartoutErrorCode.authentication },
        .{ error.BadCredentialsWithLocalOptions, api.PartoutErrorCode.openVPNRecoverableAuthentication },
        .{ error.CompressionMismatch, api.PartoutErrorCode.openVPNCompressionMismatch },
        .{ error.CryptoDerivation, api.PartoutErrorCode.openVPNUnsupportedAlgorithm },
        .{ error.CryptoEncryption, api.PartoutErrorCode.crypto },
        .{ error.InvalidEndpoint, api.PartoutErrorCode.invalidValue },
        .{ error.InvalidPushReply, api.PartoutErrorCode.openVPNConnectionFailure },
        .{ error.LinkFailure, api.PartoutErrorCode.openVPNConnectionFailure },
        .{ error.ModulesAllocation, api.PartoutErrorCode.unhandled },
        .{ error.MuxFailure, api.PartoutErrorCode.fdUnavailable },
        .{ error.NetworkChanged, api.PartoutErrorCode.networkChanged },
        .{ error.NoRouting, api.PartoutErrorCode.openVPNNoRouting },
        .{ error.ServerShutdown, api.PartoutErrorCode.openVPNServerShutdown },
        .{ error.TLSFailure, api.PartoutErrorCode.openVPNTLSFailure },
        .{ error.Timeout, api.PartoutErrorCode.timeout },
        .{ error.TunNotAvailable, api.PartoutErrorCode.tunNotAvailable },
        .{ error.UnsupportedAlgorithm, api.PartoutErrorCode.openVPNUnsupportedAlgorithm },
        .{ error.UnsupportedCompression, api.PartoutErrorCode.openVPNUnsupportedCompression },
    };

    inline for (cases) |entry|
        try std.testing.expectEqual(entry[1], codeForError(entry[0]));
}
