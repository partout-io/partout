// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

pub const c = @cImport({
    @cInclude("openvpn/openvpn.h");
});

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
    };
}
