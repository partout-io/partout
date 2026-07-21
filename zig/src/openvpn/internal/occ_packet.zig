// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

pub const OCCPacket = enum(u8) {
    exit = 0x06,

    pub const magic_string = [_]u8{
        0x28, 0x7f, 0x34, 0x6b, 0xd4, 0xef, 0x7a, 0x81,
        0x2d, 0x56, 0xb8, 0xd3, 0xaf, 0xc5, 0x45, 0x9c,
    };

    pub fn serialized(self: OCCPacket) [magic_string.len + 1]u8 {
        var result: [magic_string.len + 1]u8 = undefined;
        @memcpy(result[0..magic_string.len], &magic_string);
        result[magic_string.len] = @intFromEnum(self);
        return result;
    }
};

test "exit OCC packet matches OpenVPN magic" {
    const raw = OCCPacket.exit.serialized();
    try std.testing.expectEqual(@as(usize, 17), raw.len);
    try std.testing.expectEqual(@as(u8, 0x28), raw[0]);
    try std.testing.expectEqual(@as(u8, 0x06), raw[16]);
}
