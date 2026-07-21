// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

pub const RenegotiationType = enum {
    client,
    server,
};

test "renegotiation initiator is explicit" {
    const std = @import("std");
    try std.testing.expect(RenegotiationType.client != .server);
}
