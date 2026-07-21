// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const c = @import("c.zig").api;

pub const DataChannel = struct {
    pub const prng_seed_length: usize = 64;
    pub const aead_tag_length: usize = 16;
    pub const aead_id_length: usize = c.OpenVPNPacketIdLength;
    pub const ping_string = [_]u8{
        0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
        0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48,
    };
    pub const uses_replay_protection = true;
};

test "OpenVPN ping payload is 16 bytes" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 16), DataChannel.ping_string.len);
}
