// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Platform I/O. Callers serialize lifecycle operations. POSIX borrows the
//! caller's mux. Windows posts WinRT receives to the caller's mailbox and waits
//! on its wake event. POSIX runs read callbacks in loopOnce(). Read packet views
//! expire when the callback returns.

const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const looper_posix = @import("looper_posix.zig");
const looper_windows = @import("looper_windows.zig");

pub const testing_helpers = if (builtin.is_test) helpers else void;
pub const SubmissionError = helpers.SubmissionError;

pub const Looper = struct {
    pub const Impl = if (builtin.os.tag == .windows)
        looper_windows.WindowsLooper
    else
        looper_posix.PosixLooper;

    pub const Options = helpers.Options;
    pub const AttachArguments = helpers.AttachArguments;
    pub const AttachError = helpers.AttachError;
    pub const DetachError = helpers.DetachError;
    pub const WriteError = helpers.WriteError;
    pub const PacketSubmission = helpers.PacketSubmission;

    allocator: std.mem.Allocator,
    impl: *Impl,
    mailbox_job_limit: usize,

    /// Allocates a looper. A supplied mux is borrowed through destroy().
    pub fn create(
        allocator: std.mem.Allocator,
        options: Options,
    ) helpers.InitError!*Looper {
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

    pub fn init(allocator: std.mem.Allocator, options: Options) helpers.InitError!Looper {
        return .{
            .allocator = allocator,
            .impl = try Impl.create(allocator, options),
            .mailbox_job_limit = if (builtin.os.tag == .windows) options.max_read_count else std.math.maxInt(usize),
        };
    }

    pub fn deinit(self: *Looper) void {
        self.impl.destroy();
    }

    pub fn loopOnce(self: *Looper, failure: *?io.Failure) bool {
        return self.impl.loopOnce(null, failure);
    }

    pub fn inputReady(self: *Looper, submission: PacketSubmission) bool {
        if (builtin.os.tag == .windows) return self.impl.inputReady(submission);
        return true;
    }

    pub fn deliver(self: *Looper, submission: PacketSubmission) void {
        if (builtin.os.tag == .windows) self.impl.deliver(submission);
    }

    /// Attempts queued writes once without running protocol callbacks or waiting.
    pub fn flushWrites(self: *Looper, side: io.Side) DetachError!?io.Failure {
        return self.impl.flushWrites(side);
    }

    /// Synchronously cancels pending work. Must run outside callbacks.
    pub fn stop(self: *Looper) helpers.StopError!void {
        return self.impl.stop();
    }

    /// Replaces one delayed task and executes its callback on the looper.
    ///
    /// This operation is queue-confined. The looper owns the internal command;
    /// `timer` is only an identity token and its address is never retained.
    pub fn scheduleTimer(
        self: *Looper,
        timer: *io.Timer,
        delay_ms: u64,
        task: io.TimedTask,
    ) SubmissionError!void {
        return self.impl.scheduleTimer(timer, delay_ms, task);
    }

    /// Cancels one delayed task. After this returns, its borrowed callback
    /// context cannot be invoked, even if the scheduler deadline races with
    /// cancellation. A token whose task has already run is harmless.
    pub fn cancelTimer(self: *Looper, timer: *io.Timer) void {
        return self.impl.cancelTimer(timer);
    }

    /// Ownership of `arguments.pair.io` transfers only after successful attach.
    pub fn attach(self: *Looper, arguments: AttachArguments) helpers.AttachError!void {
        return self.impl.attach(arguments);
    }

    /// Detaches a side synchronously without allocating a command node.
    pub fn detach(self: *Looper, side: io.Side) helpers.DetachError!void {
        return self.impl.detach(side);
    }

    pub fn isLinkAttached(self: *Looper) bool {
        return self.impl.isAttached(.link);
    }

    pub fn isTunAttached(self: *Looper) bool {
        return self.impl.isAttached(.tun);
    }

    pub fn resumeReading(self: *Looper, side: io.Side) SubmissionError!void {
        return self.impl.resumeReading(side);
    }

    /// POSIX copies the batch and writes it in FIFO order during loopOnce().
    /// Windows copies packets into its native asynchronous write queue.
    /// The destination is stored by value. Empty batches are no-ops.
    /// Unconnected UDP requires a destination. Side failures use on_failure;
    /// rejected datagrams are dropped without detaching the socket.
    pub fn write(
        self: *Looper,
        packets: io.Packets,
        side: io.Side,
        destination: ?io.SocketAddress,
    ) WriteError!void {
        return self.impl.write(packets, side, destination);
    }
};
