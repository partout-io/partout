// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Shared looper API. The implementation is selected at initialization and
//! remains fixed for its lifetime. Keep this object at a stable address from
//! start() until stop()/deinit() completes; callbacks borrow their contexts.

const std = @import("std");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const legacy = @import("looper.zig");
const experimental = @import("looper_v2.zig");

pub const Looper = struct {
    pub const Packet = helpers.Packet;
    pub const Packets = helpers.Packets;
    pub const ReadAction = helpers.ReadAction;
    pub const OnRead = helpers.OnRead;
    pub const Failure = helpers.Failure;
    pub const OnFailure = helpers.OnFailure;
    pub const OnFinish = helpers.OnFinish;
    pub const Task = helpers.Task;
    pub const TimedTask = helpers.TimedTask;
    pub const Timer = helpers.Timer;
    pub const Descriptor = helpers.Descriptor;
    pub const DescriptorPair = helpers.DescriptorPair;
    pub const AttachArguments = helpers.AttachArguments;
    pub const Options = helpers.Options;
    pub const SubmissionError = helpers.SubmissionError;
    pub const InitError = helpers.InitError;
    pub const StartError = helpers.StartError;
    pub const AttachError = helpers.AttachError;
    pub const DetachError = helpers.DetachError;
    pub const ResumeReadingError = helpers.ResumeReadingError;
    pub const StopError = helpers.StopError;
    pub const WriteError = helpers.WriteError;
    pub const WriteOOBError = helpers.WriteOOBError;

    implementation: union(enum) {
        legacy: legacy.Looper,
        experimental: experimental.Looper,
    },

    pub fn init(allocator: std.mem.Allocator, options: Options) InitError!Looper {
        return .{ .implementation = .{ .legacy = try legacy.Looper.init(allocator, options) } };
    }

    pub fn initExperimental(allocator: std.mem.Allocator, options: Options) InitError!Looper {
        return .{ .implementation = .{ .experimental = try experimental.Looper.init(allocator, options) } };
    }

    pub fn deinit(self: *Looper) void {
        return switch (self.implementation) {
            inline else => |*impl| impl.deinit(),
        };
    }

    pub fn start(self: *Looper) StartError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.start(),
        };
    }

    /// Requests an orderly stop and waits for the worker thread to terminate.
    ///
    /// The stop command runs after work that the looper has already accepted.
    /// Entering `.stopping` rejects new work, and delayed commands that have not
    /// become ready complete with `error.LooperUnavailable` when the worker
    /// finishes. Calling `stop` before `start`, or after the worker has already
    /// stopped, is a no-op.
    ///
    /// This function must run outside the looper thread and outside callbacks
    /// that borrow looper-owned state. It waits for an in-progress `start` or
    /// `stop` transition, but returns `error.LooperUnavailable` if `deinit` takes
    /// ownership of shutdown. The synchronous stop command is caller-owned and
    /// does not allocate.
    ///
    /// A failure that independently terminates the worker is logged by
    /// `finish` and delivered to `on_finish`; it is not returned by `stop`.
    /// `deinit` is still required to release the looper's resources.
    pub fn stop(self: *Looper) StopError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.stop(),
        };
    }

    pub fn isOnQueue(self: *Looper) bool {
        return switch (self.implementation) {
            inline else => |*impl| impl.isOnQueue(),
        };
    }

    /// Performs a task synchronously with the worker. Runs inline
    /// if on the same queue to prevent deadlock. Submission does not allocate.
    pub fn perform(self: *Looper, comptime Result: type, context: ?*anyopaque, callback: *const fn (?*anyopaque) anyerror!Result) anyerror!Result {
        return switch (self.implementation) {
            inline else => |*impl| impl.perform(Result, context, callback),
        };
    }

    pub fn performTask(self: *Looper, task: Task) anyerror!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.performTask(task),
        };
    }

    /// Replaces one delayed task and executes its callback on the looper.
    ///
    /// This operation is queue-confined. The looper owns the internal command;
    /// `timer` is only an identity token and its address is never retained.
    pub fn scheduleReplacing(self: *Looper, timer: *Timer, delay_ms: u64, task: TimedTask) SubmissionError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.scheduleReplacing(timer, delay_ms, task),
        };
    }

    /// Cancels one delayed task. After this returns, its borrowed callback
    /// context cannot be invoked, even if the scheduler deadline races with
    /// cancellation. A token whose task has already run is harmless.
    pub fn cancelTimer(self: *Looper, timer: *Timer) void {
        return switch (self.implementation) {
            inline else => |*impl| impl.cancelTimer(timer),
        };
    }

    /// Ownership of `arguments.pair.io` transfers only after successful attach.
    pub fn attach(self: *Looper, arguments: AttachArguments) AttachError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.attach(arguments),
        };
    }

    /// Detaches a side synchronously without allocating a command node.
    pub fn detach(self: *Looper, side: io.Side) DetachError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.detach(side),
        };
    }

    pub fn isLinkAttached(self: *Looper) bool {
        return switch (self.implementation) {
            inline else => |*impl| impl.isLinkAttached(),
        };
    }

    pub fn isTunAttached(self: *Looper) bool {
        return switch (self.implementation) {
            inline else => |*impl| impl.isTunAttached(),
        };
    }

    pub fn resumeReading(self: *Looper, side: io.Side) ResumeReadingError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.resumeReading(side),
        };
    }

    pub fn writeQueued(self: *Looper, packets: Packets, side: io.Side) WriteError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.writeQueued(packets, side),
        };
    }

    pub fn writeOutOfBand(self: *Looper, packets: Packets, side: io.Side) WriteOOBError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.writeOutOfBand(packets, side),
        };
    }
};
