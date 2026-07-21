// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// A pair of inbound/outbound values with a reusable reset value.
///
/// `T` must be safely value-copyable. Owning containers should expose their
/// own reset routine instead of storing duplicated ownership here.
pub fn BidirectionalState(comptime T: type) type {
    return struct {
        reset_value: T,
        inbound: T,
        outbound: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{
                .reset_value = value,
                .inbound = value,
                .outbound = value,
            };
        }

        pub fn reset(self: *Self) void {
            self.inbound = self.reset_value;
            self.outbound = self.reset_value;
        }

        pub fn pair(self: Self) [2]T {
            return .{ self.inbound, self.outbound };
        }
    };
}

test "BidirectionalState resets both directions" {
    const std = @import("std");
    var state = BidirectionalState(u32).init(7);
    state.inbound = 1;
    state.outbound = 2;
    state.reset();
    try std.testing.expectEqual([2]u32{ 7, 7 }, state.pair());
}
