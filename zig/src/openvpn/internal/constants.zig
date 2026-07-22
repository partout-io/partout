// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c = @import("c.zig").api;

pub const Control = struct {
    pub const max_payload_bytes_per_packet: usize = 1000;
    pub const early_negotiation_flags_type: u16 = 0x0001;
    pub const early_negotiation_resend_wrapped_key: u16 = 0x0001;
    pub const tls_prefix = [_]u8{ 0, 0, 0, 0, 2 };
    pub const number_of_keys: u8 = 8;
    pub const ctr_tag_length: usize = 32;
    pub const ctr_payload_length: usize =
        c.OpenVPNPacketOpcodeLength +
        c.OpenVPNPacketSessionIdLength +
        c.OpenVPNPacketReplayIdLength +
        c.OpenVPNPacketReplayTimestampLength;

    pub fn nextKey(current_key: u8) u8 {
        return @max(1, (current_key +% 1) % number_of_keys);
    }
};

pub const Data = struct {
    pub const prng_seed_length: usize = 64;
    pub const aead_tag_length: usize = 16;
    pub const aead_id_length: usize = c.OpenVPNPacketIdLength;
    pub const ping_string = [_]u8{
        0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
        0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48,
    };
    pub const uses_replay_protection = true;
};

pub const Keys = struct {
    pub const label1 = "OpenVPN master secret";
    pub const label2 = "OpenVPN key expansion";
    pub const random_length: usize = 32;
    pub const pre_master_length: usize = 48;
    pub const key_length: usize = 64;
    pub const keys_count: usize = 4;
};

pub const TLS = struct {
    pub const ca_filename = "ca.pem";
    pub const default_security_level: i32 = 0;
    pub const buffer_length: usize = 16 * 1024;
};

test "constant groups preserve protocol values" {
    try std.testing.expectEqual(@as(usize, 1000), Control.max_payload_bytes_per_packet);
    try std.testing.expectEqual(@as(u8, 1), Control.nextKey(7));
    try std.testing.expectEqual(@as(usize, 16), Data.ping_string.len);
    try std.testing.expectEqual(@as(usize, 256), Keys.keys_count * Keys.key_length);
}
