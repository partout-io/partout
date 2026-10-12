// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Caller-driven platform I/O. The caller serializes access and owns the wake
//! descriptor. loopOnce() runs callbacks inline. Read storage and queued writes
//! are owned by the looper; read packet views expire when the callback returns.
//! Legacy worker APIs remain as explicit panics during the daemon migration.

const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const looper_posix = @import("looper_posix.zig");
const looper_windows = @import("looper_windows.zig");

pub const testing_helpers = if (builtin.is_test) helpers else void;

pub const Looper = struct {
    pub const Impl = if (builtin.os.tag == .windows)
        looper_windows.WindowsLooper
    else
        looper_posix.PosixLooper;

    pub const Options = helpers.Options;
    pub const OnRead = helpers.OnRead;
    pub const ReadAction = helpers.ReadAction;
    pub const Packet = helpers.Packet;
    pub const Packets = helpers.Packets;
    pub const Failure = helpers.Failure;
    pub const OnFailure = helpers.OnFailure;
    pub const OnFinish = helpers.OnFinish;
    pub const Task = helpers.Task;
    pub const TimedTask = helpers.TimedTask;
    pub const Timer = helpers.Timer;
    pub const LinkDescriptor = io.LinkDescriptor;
    pub const TunDescriptor = io.TunDescriptor;
    pub const DescriptorPair = io.DescriptorPair;
    pub const AttachArguments = helpers.AttachArguments;
    pub const InitError = helpers.InitError;
    pub const StartError = helpers.StartError;
    pub const StopError = helpers.StopError;
    pub const AttachError = helpers.AttachError;
    pub const DetachError = helpers.DetachError;
    pub const ResumeReadingError = helpers.ResumeReadingError;
    pub const SubmissionError = helpers.SubmissionError;
    pub const WriteError = helpers.WriteError;

    allocator: std.mem.Allocator,
    impl: *Impl,

    /// Allocates a looper whose storage is released by `destroy()`.
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
        };
    }

    pub fn deinit(self: *Looper) void {
        self.impl.destroy();
    }

    pub fn loopOnce(self: *Looper, max_wait_ms: ?u32) bool {
        return self.impl.loopOnce(max_wait_ms);
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
        timer: *helpers.Timer,
        delay_ms: u64,
        task: helpers.TimedTask,
    ) helpers.SubmissionError!void {
        return self.impl.scheduleTimer(timer, delay_ms, task);
    }

    /// Cancels one delayed task. After this returns, its borrowed callback
    /// context cannot be invoked, even if the scheduler deadline races with
    /// cancellation. A token whose task has already run is harmless.
    pub fn cancelTimer(self: *Looper, timer: *helpers.Timer) void {
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

    pub fn resumeReading(self: *Looper, side: io.Side) helpers.ResumeReadingError!void {
        return self.impl.resumeReading(side);
    }

    /// Copies the complete batch before returning; loopOnce() writes it in FIFO order.
    /// The destination is stored by value. Empty batches are no-ops.
    /// Unconnected UDP requires a destination. Side failures use on_failure;
    /// rejected datagrams are dropped without detaching the socket.
    pub fn write(
        self: *Looper,
        packets: Packets,
        side: io.Side,
        destination: ?io.SocketAddress,
    ) WriteError!void {
        return self.impl.write(packets, side, destination);
    }

    // Unsupported legacy worker APIs.

    pub fn start(_: *Looper) helpers.StartError!void {
        @panic("Looper v2 is caller-driven; use loopOnce");
    }

    pub fn isOnQueue(_: *Looper) bool {
        @panic("Looper v2 has no worker queue; execution belongs to the daemon");
    }

    pub fn perform(
        _: *Looper,
        comptime Result: type,
        _: ?*anyopaque,
        _: *const fn (?*anyopaque) anyerror!Result,
    ) anyerror!Result {
        @panic("Looper v2 cannot dispatch work; execution belongs to the daemon");
    }

    pub fn performTask(_: *Looper, _: helpers.Task) anyerror!void {
        @panic("Looper v2 cannot dispatch work; execution belongs to the daemon");
    }
};
