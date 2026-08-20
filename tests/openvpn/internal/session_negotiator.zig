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
