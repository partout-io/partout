// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Shared looper API. The compile-time runtime policy may force v2.
//! The implementation remains fixed for its lifetime. Keep this object at a stable address from
//! start() until stop()/deinit() completes; callbacks borrow their contexts.

const std = @import("std");
const runtime_policy = @import("../runtime_policy.zig");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const legacy = runtime_policy.legacy_looper;
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
    pub const LinkDescriptor = io.LinkDescriptor;
    pub const TunDescriptor = io.TunDescriptor;
    pub const DescriptorPair = io.DescriptorPair;
    pub const AttachArguments = helpers.AttachArguments;
    pub const Options = helpers.Options;
    pub const SubmissionError = helpers.SubmissionError;
    pub const InitError = helpers.InitError;
    pub const StartError = helpers.StartError;
    pub const AttachError = helpers.AttachError;
    pub const DetachError = helpers.DetachError;
    pub const ResumeReadingError = helpers.ResumeReadingError;
    pub const StopError = helpers.StopError;
    // Preserve the copying facade's error contract for existing consumers.
    pub const WriteError = SubmissionError || error{MissingDestination};
    pub const WriteOOBError = helpers.WriteOOBError;

    allocator: std.mem.Allocator,
    read_storage: [2]?*ReadStorage = .{ null, null },

    implementation: if (runtime_policy.v2_only) union(enum) {
        experimental: experimental.Looper,
    } else union(enum) {
        legacy: legacy.Looper,
        experimental: experimental.Looper,
    },

    pub fn init(allocator: std.mem.Allocator, options: Options) InitError!Looper {
        if (runtime_policy.v2_only) return initExperimental(allocator, options);
        return .{ .allocator = allocator, .implementation = .{ .legacy = try legacy.Looper.init(allocator, options) } };
    }

    pub fn initExperimental(allocator: std.mem.Allocator, options: Options) InitError!Looper {
        const link = try ReadStorage.create(allocator, options, options.link_buf_size);
        errdefer link.destroy();
        const tun = try ReadStorage.create(allocator, options, options.tun_buf_size);
        errdefer tun.destroy();
        return .{
            .allocator = allocator,
            .read_storage = .{ link, tun },
            .implementation = .{ .experimental = try experimental.Looper.init(allocator, options) },
        };
    }

    pub fn deinit(self: *Looper) void {
        defer for (self.read_storage) |storage| {
            if (storage) |value| value.destroy();
        };
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
        var resolved = arguments;
        // The original facade also drained input when no observer was installed.
        if (self.implementation == .experimental and resolved.on_read == null)
            resolved.on_read = .{ .callback = discardRead };
        if (resolved.on_read != null and resolved.read_buffers == null) {
            const index: usize = switch (resolved.pair) {
                .link => 0,
                .tun => 1,
            };
            if (self.read_storage[index]) |storage| resolved.read_buffers = .{
                .context = storage,
                .acquire = ReadStorage.acquire,
                .release = ReadStorage.release,
            };
        }
        return switch (self.implementation) {
            inline else => |*impl| impl.attach(resolved),
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

    /// Copies one destination with every packet in the batch. Required for
    /// unconnected UDP; ignored by connected sockets. Pass null for TUN writes.
    pub fn writeQueued(self: *Looper, packets: Packets, side: io.Side, destination: ?io.SocketAddress) WriteError!void {
        switch (self.implementation) {
            inline else => |*impl| {
                if (@TypeOf(impl.*) == experimental.Looper) {
                    if (packets.len == 0) return;
                    const copy = try WriteCopy.create(self.allocator, packets);
                    errdefer copy.destroy();
                    impl.writeQueued(copy.packets, side, destination, .{
                        .context = copy,
                        .callback = WriteCopy.complete,
                    }) catch |err| switch (err) {
                        error.SideNotAttached, error.InvalidBuffers => copy.destroy(),
                        else => |failure| return failure,
                    };
                } else {
                    impl.writeQueued(packets, side, destination) catch |err| switch (err) {
                        error.SideNotAttached, error.InvalidBuffers => {},
                        else => |failure| return failure,
                    };
                }
            },
        }
    }

    fn discardRead(_: ?*anyopaque, _: Packets, _: ?[]const io.SocketAddress) anyerror!ReadAction {
        return .keep;
    }

    pub fn writeOutOfBand(self: *Looper, packets: Packets, side: io.Side, destination: ?io.SocketAddress) WriteOOBError!void {
        return switch (self.implementation) {
            inline else => |*impl| impl.writeOutOfBand(packets, side, destination),
        };
    }
};

// Compatibility storage for callers that still use the copying facade. The v2
// looper itself only borrows these buffers; they outlive its worker and callbacks.
const ReadStorage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    buffers: []helpers.ReadBuffer,

    fn create(allocator: std.mem.Allocator, options: helpers.Options, buffer_size: usize) std.mem.Allocator.Error!*ReadStorage {
        const size = @max(1, buffer_size);
        const count = @min(options.max_read_count, @max(1, options.max_read_size / size));
        const bytes = try allocator.alloc(u8, std.math.mul(usize, count, size) catch return error.OutOfMemory);
        errdefer allocator.free(bytes);
        const buffers = try allocator.alloc(helpers.ReadBuffer, count);
        errdefer allocator.free(buffers);
        for (buffers, 0..) |*buffer, index| buffer.* = .{ .data = bytes[index * size ..][0..size] };
        const self = try allocator.create(ReadStorage);
        self.* = .{ .allocator = allocator, .bytes = bytes, .buffers = buffers };
        return self;
    }

    fn destroy(self: *ReadStorage) void {
        const allocator = self.allocator;
        allocator.free(self.buffers);
        allocator.free(self.bytes);
        allocator.destroy(self);
    }

    fn acquire(raw: ?*anyopaque) []helpers.ReadBuffer {
        const self: *ReadStorage = @ptrCast(@alignCast(raw.?));
        return self.buffers;
    }

    fn release(_: ?*anyopaque, _: []helpers.ReadBuffer, _: helpers.IOResult) void {}
};

const WriteCopy = struct {
    allocator: std.mem.Allocator,
    packets: []helpers.Packet,

    fn create(allocator: std.mem.Allocator, packets: helpers.Packets) std.mem.Allocator.Error!*WriteCopy {
        const copies = try allocator.alloc(helpers.Packet, packets.len);
        errdefer allocator.free(copies);
        var copied: usize = 0;
        errdefer for (copies[0..copied]) |packet| allocator.free(packet);
        for (packets, copies) |packet, *copy| {
            copy.* = try allocator.dupe(u8, packet);
            copied += 1;
        }
        const self = try allocator.create(WriteCopy);
        self.* = .{ .allocator = allocator, .packets = copies };
        return self;
    }

    fn destroy(self: *WriteCopy) void {
        const allocator = self.allocator;
        for (self.packets) |packet| allocator.free(packet);
        allocator.free(self.packets);
        allocator.destroy(self);
    }

    fn complete(raw: ?*anyopaque, _: helpers.IOResult) void {
        const self: *WriteCopy = @ptrCast(@alignCast(raw.?));
        self.destroy();
    }
};
