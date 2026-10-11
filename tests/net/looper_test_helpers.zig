// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

/// Each test owns the wake source until after its looper is destroyed.
pub const WakePipe = struct {
    fds: [2]std.c.fd_t,

    pub fn init() !WakePipe {
        if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
        var self: WakePipe = undefined;
        if (std.c.pipe(&self.fds) != 0) return error.PipeFailed;
        return self;
    }

    pub fn deinit(self: WakePipe) void {
        if (comptime builtin.os.tag == .windows) return;
        _ = std.c.close(self.fds[0]);
        _ = std.c.close(self.fds[1]);
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
