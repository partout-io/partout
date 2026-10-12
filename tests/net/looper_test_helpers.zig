// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const source = @import("source");

const io_c = source.net_io.io_c;

/// Each test owns the mux until after its looper is destroyed.
pub const Mux = struct {
    handle: io_c.pp_mux,

    pub fn init() !Mux {
        if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
        return .{ .handle = io_c.pp_mux_create(2) orelse return error.MuxCreationFailed };
    }

    pub fn deinit(self: Mux) void {
        io_c.pp_mux_free(self.handle);
    }

    pub fn signal(self: Mux) void {
        std.debug.assert(io_c.pp_mux_wake(self.handle));
    }

    pub fn reset(self: Mux) !void {
        try std.testing.expect(io_c.pp_mux_reset_wake(self.handle));
    }
};

/// Bound waits while advancing I/O synchronously on the test thread.
pub fn wait(loop: anytype, value: anytype, expected: usize) !void {
    for (0..500) |_| {
        if (value.load(.acquire) >= expected) return;
        if (!loop.loopOnce(10)) return error.LooperStopped;
    }
    return error.Timeout;
}
