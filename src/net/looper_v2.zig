// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Serial, mux-backed I/O loop for a link descriptor and a tunnel descriptor.
//!
//! `Looper` is the Zig counterpart of Darwin's `FdLooper`. The object must stay
//! at a stable address from `start()` until `stop()`/`deinit()` has completed.
//! Callback contexts are borrowed and must outlive the attachment (or the
//! looper itself for `OnFinish`). Packet slices passed to callbacks are borrowed
//! for the duration of the callback. `writeQueued()` copies packet slices before
//! queuing them.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("../core/exports.zig");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const log = core.logging;

pub const Looper = struct {
    pub const Impl = if (builtin.os.tag == .windows)
        @import("looper_windows.zig").WindowsLooper
    else
        @import("looper_posix.zig").PosixLooper;

    pub const Options = helpers.Options;
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
    pub const LinkDescriptor = helpers.LinkDescriptor;
    pub const TunDescriptor = helpers.TunDescriptor;
    pub const DescriptorPair = helpers.DescriptorPair;
    pub const AttachArguments = helpers.AttachArguments;
    pub const InitError = helpers.InitError;
    pub const StartError = helpers.StartError;
    pub const StopError = helpers.StopError;
    pub const AttachError = helpers.AttachError;
    pub const DetachError = helpers.DetachError;
    pub const ResumeReadingError = helpers.ResumeReadingError;
    pub const SubmissionError = helpers.SubmissionError;
    pub const WriteError = helpers.WriteError;
    pub const WriteOOBError = helpers.WriteOOBError;

    allocator: std.mem.Allocator,
    impl: *Impl,

    /// Allocates a looper whose storage is released by `destroy()`.
    pub fn create(allocator: std.mem.Allocator, options: helpers.Options) helpers.InitError!*Looper {
        const self = try allocator.create(Looper);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, options);
        return self;
    }

    /// Deinitializes and frees a looper allocated by `create()`.
    pub fn destroy(self: *Looper) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn init(allocator: std.mem.Allocator, options: helpers.Options) helpers.InitError!Looper {
        return .{
            .allocator = allocator,
            .impl = try Impl.create(allocator, options),
        };
    }

    pub fn deinit(self: *Looper) void {
        self.impl.destroy();
    }

    pub fn start(self: *Looper) helpers.StartError!void {
        return self.impl.start();
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
    pub fn stop(self: *Looper) helpers.StopError!void {
        return self.impl.stop();
    }

    pub fn isOnQueue(self: *Looper) bool {
        return self.impl.isOnQueue();
    }

    /// Performs a task synchronously with the worker. Runs inline
    /// if on the same queue to prevent deadlock. Submission does not allocate.
    // FIXME: ###, anyerror
    pub fn perform(
        self: *Looper,
        comptime Result: type,
        context: ?*anyopaque,
        callback: *const fn (?*anyopaque) anyerror!Result,
    ) anyerror!Result {
        return self.impl.perform(Result, context, callback);
    }

    // FIXME: ###, anyerror
    pub fn performTask(self: *Looper, task: helpers.Task) anyerror!void {
        return self.impl.performTask(task);
    }

    /// Replaces one delayed task and executes its callback on the looper.
    ///
    /// This operation is queue-confined. The looper owns the internal command;
    /// `timer` is only an identity token and its address is never retained.
    pub fn scheduleReplacing(
        self: *Looper,
        timer: *helpers.Timer,
        delay_ms: u64,
        task: helpers.TimedTask,
    ) helpers.SubmissionError!void {
        return self.impl.scheduleReplacing(timer, delay_ms, task);
    }

    /// Cancels one delayed task. After this returns, its borrowed callback
    /// context cannot be invoked, even if the scheduler deadline races with
    /// cancellation. A token whose task has already run is harmless.
    pub fn cancelTimer(self: *Looper, timer: *helpers.Timer) void {
        return self.impl.cancelTimer(timer);
    }

    /// Ownership of `arguments.pair.io` transfers only after successful attach.
    pub fn attach(self: *Looper, arguments: helpers.AttachArguments) helpers.AttachError!void {
        return self.impl.attach(arguments);
    }

    /// Detaches a side synchronously without allocating a command node.
    pub fn detach(self: *Looper, side: io.Side) helpers.DetachError!void {
        return self.impl.detach(side);
    }

    pub fn isLinkAttached(self: *Looper) bool {
        return self.impl.isLinkAttached();
    }

    pub fn isTunAttached(self: *Looper) bool {
        return self.impl.isTunAttached();
    }

    pub fn resumeReading(self: *Looper, side: io.Side) helpers.ResumeReadingError!void {
        return self.impl.resumeReading(side);
    }

    pub fn writeQueued(
        self: *Looper,
        packets: helpers.Packets,
        side: io.Side,
    ) helpers.WriteError!void {
        return self.impl.writeQueued(packets, side);
    }

    pub fn writeOutOfBand(self: *Looper, packets: helpers.Packets, side: io.Side) helpers.WriteOOBError!void {
        return self.impl.writeOutOfBand(packets, side);
    }
};
