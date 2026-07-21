// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Ordered phases of an OpenVPN key negotiation.
pub const NegotiatorState = enum(u8) {
    idle,
    tls,
    auth,
    push,
    connected,

    pub fn before(self: NegotiatorState, other: NegotiatorState) bool {
        return @intFromEnum(self) < @intFromEnum(other);
    }
};

test "NegotiatorState preserves Swift ordering" {
    const std = @import("std");
    try std.testing.expect(NegotiatorState.tls.before(.auth));
    try std.testing.expect(!NegotiatorState.connected.before(.push));
}
