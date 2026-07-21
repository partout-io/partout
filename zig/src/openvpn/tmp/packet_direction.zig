// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

pub const Direction = enum {
    outbound,
    inbound,
};

pub const PacketDirection = Direction;

test "packet directions remain distinct" {
    const std = @import("std");
    try std.testing.expect(Direction.outbound != Direction.inbound);
}
