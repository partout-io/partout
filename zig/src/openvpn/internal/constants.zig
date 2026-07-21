// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

pub const Constants = struct {
    pub const Keys = @import("key_constants.zig").Keys;
    pub const ControlChannel = @import("control_channel_constants.zig").ControlChannel;
    pub const DataChannel = @import("data_channel_constants.zig").DataChannel;
};

test "constants namespace re-exports entity files" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 48), Constants.Keys.pre_master_length);
    try std.testing.expectEqual(@as(usize, 1000), Constants.ControlChannel.max_payload_bytes_per_packet);
}
