// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_common = @import("../../c/exports.zig").common;
const errors = @import("errors.zig");
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

/// Pseudo-random byte source, ported from `PRNGProtocol`.
pub const PRNG = struct {
    context: ?*anyopaque = null,
    fill_fn: *const fn (?*anyopaque, []u8) bool = systemFill,

    pub fn system() PRNG {
        return .{};
    }

    pub fn fill(self: PRNG, destination: []u8) errors.PRNGError!void {
        if (!self.fill_fn(self.context, destination)) return error.RandomGeneration;
    }

    pub fn data(
        self: PRNG,
        allocator: std.mem.Allocator,
        length: usize,
    ) (std.mem.Allocator.Error || errors.PRNGError)![]u8 {
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        try self.fill(bytes);
        return bytes;
    }

    pub fn safeData(
        self: PRNG,
        allocator: std.mem.Allocator,
        length: usize,
    ) (std.mem.Allocator.Error || errors.PRNGError)!ZeroingData {
        var result = try ZeroingData.init(allocator, length);
        errdefer result.deinit(allocator);
        try self.fill(result.bytes);
        return result;
    }

    fn systemFill(_: ?*anyopaque, destination: []u8) bool {
        if (destination.len == 0) return true;
        return c_common.pp_prng_do(destination.ptr, destination.len);
    }
};
