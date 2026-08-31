// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const session_negotiator = source.openvpn_internal.session_negotiator;

const Negotiator = session_negotiator.Negotiator;
const NegotiatorState = session_negotiator.NegotiatorState;
const RenegotiationType = session_negotiator.RenegotiationType;

test "renegotiation initiator is explicit" {
    try std.testing.expect(RenegotiationType.client != .server);
}

test "NegotiatorState preserves Swift ordering" {
    try std.testing.expect(NegotiatorState.tls.before(.auth));
    try std.testing.expect(!NegotiatorState.connected.before(.push));
}

test "Negotiator declarations are semantically analyzed" {
    std.testing.refAllDecls(Negotiator);
}

test "early-negotiation TLV requests wrapped-key resend" {
    const payload = [_]u8{
        0x00, 0x01,
        0x00, 0x02,
        0x00, 0x01,
    };
    try std.testing.expect(session_negotiator.testing.requestsWrappedKeyResend(&payload));
    try std.testing.expect(!session_negotiator.testing.requestsWrappedKeyResend(payload[0..5]));
}

test "new negotiations reuse session tokens without applying OTP formatting" {
    const api = source.core.api;
    const AuthToken = source.openvpn_internal.auth.AuthToken;
    const allocator = std.testing.allocator;
    const methods = [_]api.OpenVPNCredentialsOTPMethod{ .none, .append, .encode };
    for (methods) |method| {
        var credentials = try source.openvpn_internal.configuration.credentialsForAuthentication(allocator, .{
            .username = "user",
            .password = "password",
            .otp_method = method,
            .otp = "123456",
        });
        defer credentials.deinit(allocator);
        var token = AuthToken{ .allocator = allocator };
        defer token.deinit();
        const options = session_negotiator.NegotiatorOptions{
            .configuration = &.{},
            .credentials = &credentials,
            .auth_token = &token,
            .with_local_options = true,
            .session_options = .{ .backend = .mock },
            .callback_context = null,
            .schedule_negotiation_check = struct {
                fn call(_: ?*anyopaque, _: u64) source.net.Looper.ScheduleTimerError!void {}
            }.call,
        };
        // Replacement sessions have no negotiation history.
        var initial = try options.newAuthenticator(allocator, .system(), null);
        defer initial.deinit();
        try std.testing.expectEqualStrings(credentials.password, initial.password.?.asSlice());

        const issued = try allocator.dupe(u8, "session-token");
        try token.update(issued);
        allocator.free(issued);
        var reconnect = try options.newAuthenticator(allocator, .system(), null);
        defer reconnect.deinit();
        try std.testing.expectEqualStrings("user", reconnect.username.?.asSlice());
        try std.testing.expectEqualStrings("session-token", reconnect.password.?.asSlice());

        try token.update(null);
        try token.update("");
        var unchanged = try options.newAuthenticator(allocator, .system(), null);
        defer unchanged.deinit();
        try std.testing.expectEqualStrings("session-token", unchanged.password.?.asSlice());

        try token.update("renewed-token");
        var renewed = try options.newAuthenticator(allocator, .system(), null);
        defer renewed.deinit();
        try std.testing.expectEqualStrings("renewed-token", renewed.password.?.asSlice());
        try std.testing.expectEqualStrings("session-token", reconnect.password.?.asSlice());

        token.clear();
        var fresh = try options.newAuthenticator(allocator, .system(), null);
        defer fresh.deinit();
        try std.testing.expectEqualStrings(credentials.password, fresh.password.?.asSlice());
    }
}
