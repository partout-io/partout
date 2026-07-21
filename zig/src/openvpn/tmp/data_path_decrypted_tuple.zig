// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

pub const DataPathDecryptedTuple = struct {
    packet_id: u32,
    data: []u8,

    pub fn init(packet_id: u32, data: []u8) DataPathDecryptedTuple {
        return .{ .packet_id = packet_id, .data = data };
    }

    pub fn deinit(self: *DataPathDecryptedTuple, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};
