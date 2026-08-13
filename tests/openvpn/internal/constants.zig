// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const constants = @import("source").openvpn_internal.constants;

test "constant groups preserve protocol values" {
    try std.testing.expectEqual(@as(usize, 1000), constants.Control.max_payload_bytes_per_packet);
    try std.testing.expectEqual(@as(u8, 1), constants.Control.nextKey(7));
    try std.testing.expectEqual(@as(usize, 16), constants.Data.ping_string.len);
    try std.testing.expectEqual(@as(usize, 256), constants.Keys.keys_count * constants.Keys.key_length);
}
