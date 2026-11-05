// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");
const source = @import("source");
const c = source.ffi.io;

/// Standalone tests own the native runtime that their workers/transports borrow.
pub const NativeRuntime = struct {
    loop: ?*anyopaque = null,

    pub fn init() !NativeRuntime {
        if (comptime builtin.os.tag != .windows or !source.windows_enabled) return .{};
        return .{
            .loop = c.windows_loop_create() orelse return error.NativeRuntimeUnavailable,
        };
    }

    pub fn deinit(self: NativeRuntime) void {
        if (comptime builtin.os.tag != .windows or !source.windows_enabled) return;
        if (self.loop) |loop| {
            c.windows_loop_drain(@ptrCast(loop));
            c.windows_loop_free(@ptrCast(loop));
        }
    }
};
