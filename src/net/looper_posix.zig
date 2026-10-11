// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Caller-driven POSIX I/O. Ready to use after create(); loopOnce() advances
//! timers and nonblocking packet I/O on the calling thread. Serialize all access.
//! Callbacks may submit writes, resume reads, and manage timers. They must not
//! attach, detach, stop, destroy, or recursively call loopOnce().
//! Packet storage is borrowed until completion; detach/stop/destroy cancel
//! pending writes. This experimental implementation is not used by the daemon.
//! The caller owns the wake descriptor, signals it from external producers, and
//! resets it before draining external work between iterations. The looper only
//! polls it; all access to the looper itself must still be serialized.

const std = @import("std");
const core = @import("../core/exports.zig");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const io_posix = @import("io_posix.zig");
const io_c = io.io_c;

pub const PosixLooper = struct {
    const retry_delay_ms = 10;
    const Scheduled = struct {
        id: u64,
        deadline_ns: u64,
        task: helpers.TimedTask,
        ready: bool = false,
        next: ?*Scheduled = null,

        fn hasId(self: *const Scheduled, id: u64) bool {
            return self.id == id;
        }
        fn isReady(self: *const Scheduled, _: void) bool {
            return self.ready;
        }
    };

    allocator: std.mem.Allocator,
    options: helpers.Options,
    mux: io_c.pp_mux,
    stopped: bool = false,
    // Protects active stack frames from callback-driven destruction, not threads.
    busy: bool = false,
    sides: [2]?*SideIO = .{ null, null },
    timers: core.Fifo(Scheduled) = .{},
    next_timer_id: u64 = 1,

    /// Borrows a readable wake descriptor (e.g. a pipe or eventfd). Keep it open
    /// through destroy(); the looper never reads, resets, writes, or closes it.
    pub fn create(
        allocator: std.mem.Allocator,
        options: helpers.Options,
    ) (helpers.InitError || error{InvalidWakeDescriptor})!*PosixLooper {
        const wake_fd = options.wake_fd orelse return error.InvalidWakeDescriptor;
        if (wake_fd < 0) return error.InvalidWakeDescriptor;
        // The external wake is a normal readable mux entry: pp_mux_wait leaves
        // it signalled for its owner, unlike the mux's own internal wake pipe.
        const mux = io_c.pp_mux_create(3) orelse return error.MuxFailure;
        errdefer io_c.pp_mux_free(mux);
        if (!io_c.pp_mux_add(mux, wake_fd)) return error.MuxFailure;
        const self = try allocator.create(PosixLooper);
        self.* = .{ .allocator = allocator, .options = options, .mux = mux };
        io_c.pp_mux_set_on_readable(mux, onReadable, self);
        io_c.pp_mux_set_on_writable(mux, onWritable, self);
        return self;
    }

    pub fn destroy(self: *PosixLooper) void {
        if (self.busy) @panic("Looper.destroy() must run outside callbacks");
        self.busy = true;
        self.clear();
        io_c.pp_mux_free(self.mux);
        self.allocator.destroy(self);
    }

    /// Zero polls without blocking; null waits for I/O, wake, or the next deadline.
    /// Otherwise waits at most max_wait_ms. Returns false after stop/fatal failure.
    /// Wake readiness lets the iteration return with true, leaving the signal for
    /// the caller to reset. The caller must keep its wake source valid.
    /// Tasks scheduled by callbacks become eligible on the next iteration.
    pub fn loopOnce(self: *PosixLooper, max_wait_ms: ?u32) bool {
        if (self.busy) @panic("Looper.loopOnce() must not be reentrant");
        if (self.stopped) return false;
        self.busy = true;
        defer self.busy = false;

        if (self.waitReady(max_wait_ms)) |code| {
            self.clear();
            self.options.on_finish.call(.{ .wait = code });
            return false;
        }
        const now = core.monotonicNs();
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next) node.ready = node.deadline_ns <= now;
        while (self.timers.removeWhere({}, Scheduled.isReady)) |node| {
            const task = node.task;
            self.allocator.destroy(node);
            task.call();
        }
        for (self.sides) |maybe_side| {
            const side = maybe_side orelse continue;
            if (side.read_retry) |deadline| {
                if (deadline <= now) side.read_retry = null;
            }
            if (side.write_retry) |deadline| {
                if (deadline <= now) {
                    side.write_retry = null;
                    side.write_ready = true;
                }
            }
        }

        // Drain outgoing batches before accepting more input. Read TUN first.
        for ([_]io.Side{ .link, .tun }) |tag| {
            const side = self.sides[@intFromEnum(tag)] orelse continue;
            if (side.write_ready and side.write_retry == null) {
                if (self.processWrite(side)) |failure| {
                    self.removeSide(tag, failure);
                    return true;
                }
            }
        }
        for ([_]io.Side{ .tun, .link }) |tag| {
            const side = self.sides[@intFromEnum(tag)] orelse continue;
            if (side.read_ready and side.reading and side.read_retry == null) {
                if (self.processRead(side)) |failure| {
                    self.removeSide(tag, failure);
                    return true;
                }
            }
        }
        return true;
    }

    /// Cancels pending work, cleans attached sides, and invokes on_finish once.
    pub fn stop(self: *PosixLooper) error{ReentrantCall}!void {
        if (self.busy) return error.ReentrantCall;
        if (self.stopped) return;
        self.busy = true;
        defer self.busy = false;
        self.clear();
        self.options.on_finish.call(null);
    }

    /// Failed replacement preserves the old task. The token's address is not retained.
    pub fn scheduleReplacing(self: *PosixLooper, timer: *helpers.Timer, delay_ms: u64, task: helpers.TimedTask) helpers.SubmissionError!void {
        if (self.stopped) return error.LooperUnavailable;
        const node = try self.allocator.create(Scheduled);
        node.* = .{ .id = self.next_timer_id, .deadline_ns = deadlineAfter(delay_ms), .task = task };
        self.next_timer_id +%= 1;
        if (self.next_timer_id == 0) self.next_timer_id = 1;
        self.cancelTimer(timer);
        self.timers.append(node);
        timer.id = node.id;
    }

    pub fn cancelTimer(self: *PosixLooper, timer: *helpers.Timer) void {
        const id = timer.id orelse return;
        if (self.timers.removeWhere(id, Scheduled.hasId)) |node| self.allocator.destroy(node);
        timer.id = null;
    }

    /// Native I/O ownership transfers only after successful attachment.
    pub fn attach(self: *PosixLooper, arguments: helpers.AttachArguments) helpers.AttachError!void {
        if (self.busy) return error.ReentrantCall;
        if (self.stopped) return error.LooperUnavailable;
        if (arguments.read_buffers == null or self.options.max_read_count == 0) return error.InvalidBuffers;
        const tag = std.meta.activeTag(arguments.pair);
        const slot = &self.sides[@intFromEnum(tag)];
        if (slot.* != null) return error.SideAlreadyAttached;
        const descriptor = switch (arguments.pair) {
            inline else => |value| value,
        };
        if (descriptor.fd < 0 or descriptor.fd == self.options.wake_fd.? or
            (descriptor.io.isUnconnected() and tag != .link)) return error.MuxFailure;
        for (self.sides) |other| {
            if (other) |side| if (side.fd == descriptor.fd) return error.MuxFailure;
        }
        if (!io_c.pp_mux_add(self.mux, descriptor.fd)) return error.MuxFailure;
        errdefer _ = io_c.pp_mux_delete(self.mux, descriptor.fd);
        slot.* = try SideIO.create(self.allocator, tag, descriptor, arguments, self.options.max_read_count);
    }

    pub fn detach(self: *PosixLooper, tag: io.Side) helpers.DetachError!void {
        if (self.busy) return error.ReentrantCall;
        if (self.stopped) return error.LooperUnavailable;
        self.busy = true;
        defer self.busy = false;
        self.removeSide(tag, null);
    }

    pub fn isAttached(self: *const PosixLooper, tag: io.Side) bool {
        return self.sides[@intFromEnum(tag)] != null;
    }

    pub fn resumeReading(self: *PosixLooper, tag: io.Side) error{LooperUnavailable}!void {
        if (self.stopped) return error.LooperUnavailable;
        if (self.sides[@intFromEnum(tag)]) |side| {
            side.reading = true;
            side.read_retry = null;
        }
    }

    /// Queues the batch for loopOnce(), borrowing it until completion.
    /// Rejection never invokes completion.
    pub fn write(self: *PosixLooper, packets: helpers.Packets, tag: io.Side, destination: ?io.SocketAddress, completion: helpers.OnWriteComplete) helpers.WriteError!void {
        if (packets.len == 0) return error.InvalidBuffers;
        if (self.stopped) return error.LooperUnavailable;
        const side = self.sides[@intFromEnum(tag)] orelse return error.SideNotAttached;
        if (side.native_io.isUnconnected() and destination == null) return error.MissingDestination;
        const request = try self.allocator.create(helpers.WriteRequest);
        request.* = .{ .packets = packets, .destination = destination, .completion = completion };
        side.write_queue.append(request);
        if (side.write_retry == null) side.write_ready = true;
    }

    fn processWrite(self: *PosixLooper, side: *SideIO) ?helpers.Failure {
        defer side.write_ready = false;
        while (side.write_queue.head) |request| {
            const pending = request.pendingWrite();
            const written = side.native_io.writePacket(pending.data, pending.offset, pending.address) catch |err| {
                switch (err) {
                    error.WouldBlock => return null,
                    error.Backpressure => {
                        const deadline = deadlineAfter(retry_delay_ms);
                        side.write_retry = deadline;
                        const opposite: io.Side = if (side.side == .link) .tun else .link;
                        if (self.sides[@intFromEnum(opposite)]) |other| {
                            if (other.reading and other.read_retry == null) other.read_retry = deadline;
                        }
                        return null;
                    },
                    else => {
                        _ = side.write_queue.take();
                        const failure = side.ioFailure(err);
                        request.complete(self.allocator, err);
                        if (err == error.DatagramDropped) continue;
                        return failure;
                    },
                }
            };
            if (request.advance(written)) {
                _ = side.write_queue.take();
                request.complete(self.allocator, null);
            } else if (written == 0) {
                // A zero-byte stream write must not monopolize this iteration.
                return null;
            }
        }
        return null;
    }

    fn processRead(self: *PosixLooper, side: *SideIO) ?helpers.Failure {
        const buffers = side.read_buffers.acquire(side.read_buffers.context);
        const result = side.readPackets(buffers, self.options.max_read_size);
        defer {
            @memset(side.read_packets[0..result.count], &.{});
            side.read_buffers.release(side.read_buffers.context, buffers, result);
        }
        var action: helpers.ReadAction = if (buffers.len == 0) .pause else .keep;
        if (result.count > 0) {
            if (side.on_read) |callback| {
                const addresses = if (side.read_addresses) |values| values[0..result.count] else null;
                action = callback.call(side.read_packets[0..result.count], addresses) catch |err| return .{ .user = err };
            }
        }
        if (result.failure) |err| return if (err == error.InvalidBuffers) .{ .user = err } else side.ioFailure(@errorCast(err));
        if (action == .pause) side.reading = false;
        return null;
    }

    fn deadlineAfter(delay_ms: u64) u64 {
        return core.monotonicNs() +| (delay_ms *| std.time.ns_per_ms);
    }

    fn waitReady(self: *PosixLooper, max_wait_ms: ?u32) ?c_int {
        const now_ns = core.monotonicNs();
        var deadline_ns: u64 = if (max_wait_ms) |ms| now_ns +| (@as(u64, ms) * std.time.ns_per_ms) else std.math.maxInt(u64);
        var timer = self.timers.head;
        while (timer) |node| : (timer = node.next) deadline_ns = @min(deadline_ns, node.deadline_ns);
        for (self.sides) |maybe_side| {
            const side = maybe_side orelse continue;
            side.read_ready = false;
            if (side.read_retry) |ns| deadline_ns = @min(deadline_ns, ns);
            if (side.write_retry) |ns| deadline_ns = @min(deadline_ns, ns);
            if (side.write_ready and side.write_retry == null) deadline_ns = now_ns;
            _ = io_c.pp_mux_set_read(self.mux, side.fd, side.reading and side.read_retry == null);
            _ = io_c.pp_mux_set_write(self.mux, side.fd, side.write_queue.head != null and side.write_retry == null);
        }
        const remaining_ns = deadline_ns -| now_ns;
        const timeout_ms: c_int = if (deadline_ns == std.math.maxInt(u64)) -1 else @intCast(@min(std.math.maxInt(c_int), remaining_ns / std.time.ns_per_ms + @intFromBool(remaining_ns % std.time.ns_per_ms != 0)));
        var code: c_int = 0;
        if (io_c.pp_mux_wait(self.mux, timeout_ms, &code) < 0) return code;
        return null;
    }

    fn onReadable(context: ?*anyopaque, fd: io.FileDescriptor) callconv(.c) void {
        const self: *PosixLooper = @ptrCast(@alignCast(context.?));
        for (self.sides) |maybe_side| {
            if (maybe_side) |side| if (side.fd == fd) {
                side.read_ready = true;
            };
        }
    }

    fn onWritable(context: ?*anyopaque, fd: io.FileDescriptor) callconv(.c) void {
        const self: *PosixLooper = @ptrCast(@alignCast(context.?));
        for (self.sides) |maybe_side| {
            if (maybe_side) |side| if (side.fd == fd) {
                side.write_ready = true;
            };
        }
    }

    // All callers hold the reentrancy guard, including while cancelling writes.
    fn removeSide(self: *PosixLooper, tag: io.Side, failure: ?helpers.Failure) void {
        const slot = &self.sides[@intFromEnum(tag)];
        const side = slot.* orelse return;
        slot.* = null;
        _ = io_c.pp_mux_delete(self.mux, side.fd);
        if (failure) |reason| if (side.on_failure) |callback| callback.call(reason);
        side.native_io.cleanup();
        while (side.write_queue.take()) |request| request.complete(self.allocator, error.Cancelled);
        self.allocator.free(side.read_packets);
        if (side.read_addresses) |addresses| self.allocator.free(addresses);
        self.allocator.destroy(side);
    }

    fn clear(self: *PosixLooper) void {
        self.stopped = true;
        while (self.timers.take()) |node| self.allocator.destroy(node);
        self.removeSide(.link, null);
        self.removeSide(.tun, null);
    }

    const SideIO = struct {
        side: io.Side,
        fd: io.FileDescriptor,
        native_io: io_posix.POSIXInterface,
        on_read: ?helpers.OnRead,
        on_failure: ?helpers.OnFailure,
        read_buffers: helpers.ReadBuffers,
        read_packets: []helpers.Packet,
        read_addresses: ?[]io.SocketAddress,
        write_queue: core.Fifo(helpers.WriteRequest) = .{},
        reading: bool = true,
        read_ready: bool = false,
        write_ready: bool = false,
        read_retry: ?u64 = null,
        write_retry: ?u64 = null,

        fn create(allocator: std.mem.Allocator, side: io.Side, descriptor: io_posix.POSIXDescriptor, arguments: helpers.AttachArguments, max_read_count: usize) std.mem.Allocator.Error!*SideIO {
            const packets = try allocator.alloc(helpers.Packet, max_read_count);
            errdefer allocator.free(packets);
            const addresses = if (descriptor.io.isUnconnected()) try allocator.alloc(io.SocketAddress, max_read_count) else null;
            errdefer if (addresses) |values| allocator.free(values);
            const self = try allocator.create(SideIO);
            self.* = .{
                .side = side,
                .fd = descriptor.fd,
                .native_io = descriptor.io,
                .on_read = arguments.on_read,
                .on_failure = arguments.on_failure,
                .read_buffers = arguments.read_buffers.?,
                .read_packets = packets,
                .read_addresses = addresses,
            };
            return self;
        }

        fn readPackets(
            self: *SideIO,
            buffers: []helpers.ReadBuffer,
            max_size: usize,
        ) helpers.IOResult {
            var result = helpers.IOResult{};
            var size: usize = 0;
            const limit = @min(buffers.len, self.read_packets.len);
            // Count discarded packets against the attempt budget too, so an
            // oversized-packet flood cannot monopolize the looper.
            for (0..limit) |_| {
                const buffer = &buffers[result.count];
                if (buffer.data.len == 0) {
                    result.failure = error.InvalidBuffers;
                    break;
                }
                var address: io.SocketAddress = undefined;
                const count = self.native_io.readPacket(
                    buffer.data,
                    &address,
                ) catch |err| {
                    if (err == error.DatagramDropped) continue;
                    if (err != error.WouldBlock) {
                        result.failure = err;
                    }
                    break;
                } orelse break;

                buffer.size = count;
                buffer.source = null;
                self.read_packets[result.count] = buffer.data[0..count];
                if (self.read_addresses) |addresses| {
                    buffer.source = address;
                    addresses[result.count] = address;
                }
                result.count += 1;
                size += count;
                if (size >= max_size) break;
            }
            return result;
        }

        fn ioFailure(self: *const SideIO, cause: io.Error) helpers.Failure {
            return .{ .io = .{
                .side = self.side,
                .cause = cause,
                .code = if (cause == error.LibcFailure)
                    self.native_io.lastErrorCode()
                else
                    null,
            } };
        }
    };
};
