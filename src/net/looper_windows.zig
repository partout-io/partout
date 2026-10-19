// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");

// FIXME: ###, Windows, WindowsLooper
pub const WindowsLooper = struct {
    allocator: std.mem.Allocator,
    options: helpers.Options,

    stopped: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        options: helpers.Options,
    ) helpers.InitError!*WindowsLooper {
        if (options.mux == null) return error.MuxFailure;
        const self = try allocator.create(WindowsLooper);
        self.* = .{
            .allocator = allocator,
            .options = options,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.allocator.destroy(self);
    }

    pub fn loopOnce(self: *WindowsLooper, _: ?u32, failure: *?helpers.Failure) bool {
        failure.* = null;
        if (self.stopped) return false;
        @panic("WindowsLooper.loopOnce is not implemented");
    }

    pub fn stop(self: *WindowsLooper) helpers.StopError!void {
        if (self.stopped) return;
        self.stopped = true;
    }

    pub fn scheduleTimer(
        _: *WindowsLooper,
        _: *helpers.Timer,
        _: u64,
        _: helpers.TimedTask,
    ) helpers.SubmissionError!void {
        @panic("WindowsLooper.scheduleTimer is not implemented");
    }

    pub fn cancelTimer(_: *WindowsLooper, _: *helpers.Timer) void {
        @panic("WindowsLooper.cancelTimer is not implemented");
    }

    pub fn attach(
        self: *WindowsLooper,
        arguments: helpers.AttachArguments,
    ) helpers.AttachError!void {
        if (self.options.max_read_count == 0 or self.options.max_read_size == 0 or
            (if (arguments.pair == .link) self.options.link_buf_size else self.options.tun_buf_size) == 0)
        {
            return error.InvalidBuffers;
        }
        @panic("WindowsLooper.attach is not implemented");
    }

    pub fn write(
        _: *WindowsLooper,
        _: helpers.Packets,
        _: io.Side,
        _: ?io.SocketAddress,
    ) helpers.WriteError!void {
        @panic("WindowsLooper.write is not implemented");
    }

    pub fn flushWrites(_: *WindowsLooper, _: io.Side) helpers.DetachError!?helpers.Failure {
        @panic("WindowsLooper.flushWrites is not implemented");
    }

    pub fn detach(self: *WindowsLooper, side: io.Side) helpers.DetachError!void {
        _ = self;
        _ = side;
        @panic("WindowsLooper.detach is not implemented");
    }

    pub fn isAttached(_: *const WindowsLooper, _: io.Side) bool {
        return false;
    }

    pub fn resumeReading(_: *WindowsLooper, _: io.Side) helpers.ResumeReadingError!void {
        @panic("WindowsLooper.resumeReading is not implemented");
    }
};
