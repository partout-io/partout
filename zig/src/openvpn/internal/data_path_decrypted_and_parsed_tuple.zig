// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

pub const DataPathDecryptedAndParsedTuple = struct {
    packet_id: u32,
    header: u8,
    is_keep_alive: bool,
    data: []u8,

    pub fn init(
        packet_id: u32,
        header: u8,
        is_keep_alive: bool,
        data: []u8,
    ) DataPathDecryptedAndParsedTuple {
        return .{
            .packet_id = packet_id,
            .header = header,
            .is_keep_alive = is_keep_alive,
            .data = data,
        };
    }

    pub fn deinit(
        self: *DataPathDecryptedAndParsedTuple,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};
