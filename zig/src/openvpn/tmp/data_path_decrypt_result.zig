// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

/// Owning Zig representation of Swift's bulk-decrypt result tuple.
pub const DataPathDecryptResult = struct {
    packets: [][]u8,
    keep_alive: bool,

    pub fn deinit(self: *DataPathDecryptResult, allocator: std.mem.Allocator) void {
        for (self.packets) |packet| allocator.free(packet);
        allocator.free(self.packets);
        self.* = undefined;
    }
};
