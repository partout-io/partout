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

    // FIXME: ###, Windows, Initialize native event-loop resources.
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

    // FIXME: ###, Windows, Release native attachments, queued writes, and timers.
    pub fn destroy(self: *WindowsLooper) void {
        self.allocator.destroy(self);
    }

    // FIXME: ###, Windows, Dispatch native readiness events and timers.
    pub fn loopOnce(self: *WindowsLooper, _: ?u32, failure: *?io.Failure) bool {
        failure.* = null;
        if (self.stopped) return false;
        @panic("WindowsLooper.loopOnce is not implemented");
    }

    // FIXME: ###, Windows, Stop native I/O and cancel pending work.
    pub fn stop(self: *WindowsLooper) helpers.StopError!void {
        if (self.stopped) return;
        self.stopped = true;
    }

    // FIXME: ###, Windows, Schedule timers on the Windows event loop.
    pub fn scheduleTimer(
        _: *WindowsLooper,
        _: *io.Timer,
        _: u64,
        _: io.TimedTask,
    ) io.SubmissionError!void {
        @panic("WindowsLooper.scheduleTimer is not implemented");
    }

    // FIXME: ###, Windows, Cancel scheduled Windows timers.
    pub fn cancelTimer(_: *WindowsLooper, _: *io.Timer) void {
        @panic("WindowsLooper.cancelTimer is not implemented");
    }

    // FIXME: ###, Windows, Attach native link and TUN handles.
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

    // FIXME: ###, Windows, Queue and submit packet writes.
    pub fn write(
        _: *WindowsLooper,
        _: io.Packets,
        _: io.Side,
        _: ?io.SocketAddress,
    ) helpers.WriteError!void {
        @panic("WindowsLooper.write is not implemented");
    }

    // FIXME: ###, Windows, Flush queued packet writes.
    pub fn flushWrites(_: *WindowsLooper, _: io.Side) helpers.DetachError!?io.Failure {
        @panic("WindowsLooper.flushWrites is not implemented");
    }

    // FIXME: ###, Windows, Detach handles and release their owned resources.
    pub fn detach(self: *WindowsLooper, side: io.Side) helpers.DetachError!void {
        _ = self;
        _ = side;
        @panic("WindowsLooper.detach is not implemented");
    }

    // FIXME: ###, Windows, Track and report actual attachment state.
    pub fn isAttached(_: *const WindowsLooper, _: io.Side) bool {
        return false;
    }

    // FIXME: ###, Windows, Resume native read notifications.
    pub fn resumeReading(_: *WindowsLooper, _: io.Side) io.SubmissionError!void {
        @panic("WindowsLooper.resumeReading is not implemented");
    }
};
