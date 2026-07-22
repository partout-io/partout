// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const push = source.openvpn_internal.push;
const session_negotiator = source.openvpn_internal.session_negotiator;

const NegotiationHistory = session_negotiator.NegotiationHistory;
const Negotiator = session_negotiator.Negotiator;
const NegotiatorState = session_negotiator.NegotiatorState;
const PushReply = push.PushReply;
const RenegotiationType = session_negotiator.RenegotiationType;

test "renegotiation initiator is explicit" {
    try std.testing.expect(RenegotiationType.client != .server);
}

test "NegotiatorState preserves Swift ordering" {
    try std.testing.expect(NegotiatorState.tls.before(.auth));
    try std.testing.expect(!NegotiatorState.connected.before(.push));
}

test "negotiation history deep-clones push options" {
    var reply = (try PushReply.parse(std.testing.allocator, "PUSH_REPLY,ping 10")).?;
    var history = NegotiationHistory.init(&reply);
    defer history.deinit(std.testing.allocator);
    var copy = try history.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?f64, 10), copy.push_reply.options.keep_alive_interval);
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

test "successful TLS pull propagates control enqueue failure" {
    const Fake = struct {
        pub fn pullCipherText(_: *@This(), allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, "ciphertext");
        }

        fn failEnqueue(_: ?*anyopaque, _: []const u8) !void {
            return error.ControlChannelFailure;
        }
    };

    var fake: Fake = .{};
    try std.testing.expectError(
        error.ControlChannelFailure,
        session_negotiator.testing.forwardPulledCipherText(
            std.testing.allocator,
            &fake,
            null,
            Fake.failEnqueue,
        ),
    );
}
