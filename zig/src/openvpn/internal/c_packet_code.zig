// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c = @import("c.zig").api;

pub const CPacketCode = enum(u8) {
    softResetV1 = 0x03,
    controlV1 = 0x04,
    ackV1 = 0x05,
    dataV1 = 0x06,
    hardResetClientV2 = 0x07,
    hardResetServerV2 = 0x08,
    dataV2 = 0x09,
    hardResetClientV3 = 0x0a,
    controlWkcV1 = 0x0b,
    unknown = 0xff,

    pub fn fromRaw(raw: u8) ?CPacketCode {
        return switch (raw) {
            0x03 => .softResetV1,
            0x04 => .controlV1,
            0x05 => .ackV1,
            0x06 => .dataV1,
            0x07 => .hardResetClientV2,
            0x08 => .hardResetServerV2,
            0x09 => .dataV2,
            0x0a => .hardResetClientV3,
            0x0b => .controlWkcV1,
            0xff => .unknown,
            else => null,
        };
    }

    pub fn native(self: CPacketCode) c.openvpn_packet_code {
        return @intFromEnum(self);
    }

    pub fn debugName(self: CPacketCode) []const u8 {
        return switch (self) {
            .softResetV1 => "SOFT_RESET_V1",
            .controlV1 => "CONTROL_V1",
            .ackV1 => "ACK_V1",
            .dataV1 => "DATA_V1",
            .hardResetClientV2 => "HARD_RESET_CLIENT_V2",
            .hardResetServerV2 => "HARD_RESET_SERVER_V2",
            .dataV2 => "DATA_V2",
            .hardResetClientV3 => "HARD_RESET_CLIENT_V3",
            .controlWkcV1 => "CONTROL_WKC_V1",
            .unknown => "UNKNOWN(255)",
        };
    }
};

test "packet code wire values match OpenVPN" {
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(CPacketCode.controlV1));
    try std.testing.expectEqual(CPacketCode.hardResetClientV3, CPacketCode.fromRaw(0x0a).?);
    try std.testing.expect(CPacketCode.fromRaw(0x7f) == null);
    try std.testing.expectEqualStrings("UNKNOWN(255)", CPacketCode.unknown.debugName());
}
