// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

/// Key-method 2 client/server random material.
pub const Handshake = struct {
    pre_master: ZeroingData,
    random1: ZeroingData,
    random2: ZeroingData,
    server_random1: ZeroingData,
    server_random2: ZeroingData,

    pub fn clone(self: Handshake, allocator: std.mem.Allocator) std.mem.Allocator.Error!Handshake {
        var pre_master = try self.pre_master.clone(allocator);
        errdefer pre_master.deinit(allocator);
        var random1 = try self.random1.clone(allocator);
        errdefer random1.deinit(allocator);
        var random2 = try self.random2.clone(allocator);
        errdefer random2.deinit(allocator);
        var server_random1 = try self.server_random1.clone(allocator);
        errdefer server_random1.deinit(allocator);
        const server_random2 = try self.server_random2.clone(allocator);
        return .{
            .pre_master = pre_master,
            .random1 = random1,
            .random2 = random2,
            .server_random1 = server_random1,
            .server_random2 = server_random2,
        };
    }

    pub fn deinit(self: *Handshake, allocator: std.mem.Allocator) void {
        self.pre_master.deinit(allocator);
        self.random1.deinit(allocator);
        self.random2.deinit(allocator);
        self.server_random1.deinit(allocator);
        self.server_random2.deinit(allocator);
        self.* = undefined;
    }
};
