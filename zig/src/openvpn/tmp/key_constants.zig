// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

pub const Keys = struct {
    pub const label1 = "OpenVPN master secret";
    pub const label2 = "OpenVPN key expansion";
    pub const random_length: usize = 32;
    pub const pre_master_length: usize = 48;
    pub const key_length: usize = 64;
    pub const keys_count: usize = 4;
};

test "key expansion has four 64-byte outputs" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 256), Keys.keys_count * Keys.key_length);
}
