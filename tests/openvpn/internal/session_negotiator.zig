// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const session_negotiator = source.openvpn_internal.session_negotiator;

const Negotiator = session_negotiator.Negotiator;
const NegotiatorState = session_negotiator.NegotiatorState;
const RenegotiationType = session_negotiator.RenegotiationType;

fn negotiatorOptions(
    credentials: ?*const source.core.api.OpenVPNCredentials,
    token: *source.openvpn_internal.auth.AuthToken,
) session_negotiator.NegotiatorOptions {
    return .{
        .configuration = &.{},
        .credentials = credentials,
        .auth_token = token,
        .with_local_options = true,
        .session_options = .{ .backend = .mock },
        .callback_context = null,
        .schedule_negotiation_check = struct {
            fn call(_: ?*anyopaque, _: u64) source.net.Looper.ScheduleTimerError!void {}
        }.call,
    };
}

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

test "cached session tokens replace OTP credentials" {
    const api = source.core.api;
    const AuthToken = source.openvpn_internal.auth.AuthToken;
    const allocator = std.testing.allocator;
    const credentials = api.OpenVPNCredentials{
        .username = "user",
        .password = "password123456",
        .otp_method = .none,
    };
    var token = AuthToken{};
    defer token.deinit();
    const options = negotiatorOptions(&credentials, &token);

    token.update("session-token");
    var reconnect = try options.newAuthenticator(allocator, .system(), null);
    defer reconnect.deinit();
    try std.testing.expectEqualStrings("session-token", reconnect.password.?.asSlice());

    token.update("renewed-token");
    var renewed = try options.newAuthenticator(allocator, .system(), null);
    defer renewed.deinit();
    try std.testing.expectEqualStrings("renewed-token", renewed.password.?.asSlice());
}
