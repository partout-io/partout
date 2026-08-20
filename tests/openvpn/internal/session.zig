// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const net = source.net;
const PRNG = source.openvpn_internal.crypto.PRNG;
const Session = source.openvpn_internal.session.Session;
const forAuthentication = source.openvpn_internal.session.testing.forAuthentication;
const shouldSendExitNotification = source.openvpn_internal.session.testing.shouldSendExitNotification;

test "Session declarations are semantically analyzed" {
    std.testing.refAllDecls(Session);
}

test "Session borrows an externally managed Looper" {
    const Callbacks = struct {
        fn onFinish(_: ?*anyopaque, _: ?net.Looper.Failure) void {}

        fn barrier(_: ?*anyopaque) !void {}
    };

    const allocator = std.testing.allocator;
    const executor = try source.mock.MockSerializedExecutor.create(allocator);
    defer executor.destroy();
    var looper = try net.Looper.init(allocator, .{
        .on_finish = .{ .callback = Callbacks.onFinish },
    });
    defer looper.deinit();
    try looper.start();
    var looper_started = true;
    defer if (looper_started) looper.stop() catch {};

    const session = try Session.create(allocator, .{
        .executor = executor.interface(),
        .looper = &looper,
        .configuration = .{},
        .credentials = null,
        .prng = PRNG.system(),
        .caches_directory = "",
        .ca_filename = "11111111-1111-4111-8111-111111111111-ca.pem",
        .options = .{ .backend = .mock },
    });
    var session_destroyed = false;
    defer if (!session_destroyed) session.destroy();
    try std.testing.expect(session.looper == &looper);

    session.destroy();
    session_destroyed = true;
    try looper.perform(void, null, Callbacks.barrier);
    try looper.stop();
    looper_started = false;
}

test "forAuthentication appends and encodes OTP" {
    const allocator = std.testing.allocator;

    var appended = try forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .append,
        .otp = "123",
    });
    defer appended.deinit(allocator);
    try std.testing.expectEqualStrings("pass123", appended.password);

    var encoded = try forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .encode,
        .otp = "123",
    });
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings("SCRV1:cGFzcw==:MTIz", encoded.password);
}

test "session sends exit notification only for requested and network-change shutdowns" {
    try std.testing.expect(shouldSendExitNotification(null));
    try std.testing.expect(shouldSendExitNotification(error.NetworkChanged));

    const other_causes = [_]Session.Error{
        error.BadCredentials,
        error.BadCredentialsWithLocalOptions,
        error.CompressionMismatch,
        error.ConnectionFailure,
        error.CryptoFailure,
        error.NoRouting,
        error.ServerShutdown,
        error.Timeout,
        error.TLSFailure,
        error.UnsupportedAlgorithm,
        error.Reconnect,
    };
    for (other_causes) |cause| {
        try std.testing.expect(!shouldSendExitNotification(cause));
    }
}
