// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const io_c = io.io_c;
const log = core.logging;

pub const WindowsLooper = struct {
    allocator: std.mem.Allocator,
    options: helpers.Options,

    wake_fd: io.FileDescriptor,
    stopped: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        wake_fd: io.FileDescriptor,
        options: helpers.Options,
    ) helpers.InitError!*WindowsLooper {
        const self = try allocator.create(WindowsLooper);
        self.* = .{
            .allocator = allocator,
            .wake_fd = wake_fd,
            .options = options,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.allocator.destroy(self);
    }

    pub fn loopOnce(self: *WindowsLooper, _: ?u32) bool {
        if (self.stopped) return false;
        @panic("WindowsLooper.loopOnce is not implemented");
    }

    pub fn stop(self: *WindowsLooper) helpers.StopError!void {
        if (self.stopped) return;
        self.stopped = true;
        self.options.on_finish.call(null);
    }

    pub fn scheduleReplacing(
        _: *WindowsLooper,
        _: *helpers.Timer,
        _: u64,
        _: helpers.TimedTask,
    ) helpers.SubmissionError!void {
        // FIXME: ###, Implement timers
        @panic("WindowsLooper.scheduleReplacing is not implemented");
    }

    pub fn cancelTimer(_: *WindowsLooper, _: *helpers.Timer) void {
        // FIXME: ###, Implement timers
    }

    pub fn attach(
        self: *WindowsLooper,
        arguments: helpers.AttachArguments,
    ) helpers.AttachError!void {
        if (arguments.read_buffers == null or self.options.max_read_count == 0) {
            return error.InvalidBuffers;
        }
        @panic("WindowsLooper.attach is not implemented");
    }

    pub fn write(
        _: *WindowsLooper,
        _: helpers.Packets,
        _: io.Side,
        _: ?io.SocketAddress,
        _: helpers.OnWriteComplete,
    ) helpers.WriteError!void {
        @panic("WindowsLooper.write is not implemented");
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
