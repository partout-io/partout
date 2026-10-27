// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const builtin = @import("builtin");
const source = @import("source");
const c = source.ffi.io;

/// Standalone tests own the native runtime that their workers/transports borrow.
pub const NativeRuntime = struct {
    loop: ?*anyopaque = null,

    pub fn init() !NativeRuntime {
        if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return .{};
        if (c.winrt_thread_init() != 0) return error.NativeApartmentUnavailable;
        errdefer c.winrt_thread_uninit();
        return .{
            .loop = c.winrt_loop_create() orelse return error.NativeRuntimeUnavailable,
        };
    }

    pub fn deinit(self: NativeRuntime) void {
        if (comptime builtin.os.tag != .windows or !source.winrt_enabled) return;
        if (self.loop) |loop| {
            c.winrt_loop_drain(@ptrCast(loop));
            c.winrt_loop_free(@ptrCast(loop));
        }
        c.winrt_thread_uninit();
    }
};
