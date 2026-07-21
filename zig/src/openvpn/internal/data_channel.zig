// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const DataPathProtocol = @import("data_path_protocol.zig").DataPathProtocol;

/// Owns one negotiated OpenVPN data-path key slot.
pub const DataChannel = struct {
    allocator: std.mem.Allocator,
    key: u8,
    data_path: DataPathProtocol,

    /// `data_path` ownership transfers only when this function succeeds.
    pub fn create(
        allocator: std.mem.Allocator,
        key: u8,
        data_path: DataPathProtocol,
    ) std.mem.Allocator.Error!*DataChannel {
        const self = try allocator.create(DataChannel);
        self.* = .{
            .allocator = allocator,
            .key = key,
            .data_path = data_path,
        };
        return self;
    }

    pub fn destroy(self: *DataChannel) void {
        const allocator = self.allocator;
        self.data_path.deinit();
        allocator.destroy(self);
    }

    /// The caller owns the returned packet rows and outer slice.
    pub fn encrypt(
        self: *DataChannel,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror![][]u8 {
        return self.data_path.encrypt(allocator, packets, self.key);
    }

    /// The caller owns the returned packet rows and outer slice.
    pub fn decrypt(
        self: *DataChannel,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror![][]u8 {
        const result = try self.data_path.decrypt(allocator, packets);
        return result.packets;
    }
};
