// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const DataPathDecryptResult = @import("data_path_decrypt_result.zig").DataPathDecryptResult;

/// Free a packet batch returned by a data-path or data-channel operation.
pub fn freePackets(allocator: std.mem.Allocator, packets: [][]u8) void {
    for (packets) |packet| allocator.free(packet);
    allocator.free(packets);
}

/// Owning, type-erased data-path interface.
pub const DataPathProtocol = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        encrypt: *const fn (
            *anyopaque,
            std.mem.Allocator,
            []const []const u8,
            u8,
        ) anyerror![][]u8,
        decrypt: *const fn (
            *anyopaque,
            std.mem.Allocator,
            []const []const u8,
        ) anyerror!DataPathDecryptResult,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn encrypt(
        self: DataPathProtocol,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
        key: u8,
    ) anyerror![][]u8 {
        return self.vtable.encrypt(self.ptr, allocator, packets, key);
    }

    pub fn decrypt(
        self: DataPathProtocol,
        allocator: std.mem.Allocator,
        packets: []const []const u8,
    ) anyerror!DataPathDecryptResult {
        return self.vtable.decrypt(self.ptr, allocator, packets);
    }

    pub fn deinit(self: *DataPathProtocol) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};
