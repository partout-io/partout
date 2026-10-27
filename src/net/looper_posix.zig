// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Caller-driven POSIX I/O. Ready to use after create(); loopOnce() advances
//! timers and nonblocking packet I/O on the calling thread. Serialize all access.
//! Callbacks may submit writes, resume reads, and manage timers. They must not
//! attach, detach, stop, destroy, or recursively call loopOnce().
//! Owns read storage and copies outgoing packets; detach/stop/destroy discard
//! pending writes. Read packet views are valid only during on_read.
//! Borrows its caller's mux, including its built-in wake source. The caller owns
//! the mux until after looper destruction and serializes access to both.

const std = @import("std");
const ffi = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const io_posix = @import("io_posix.zig");
const io_c = ffi.io;

pub const PosixLooper = struct {
    const retry_delay_ms = 10;
    const Scheduled = struct {
        id: u64,
        deadline_ns: u64,
        task: io.TimedTask,
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
    stopped: bool = false,
    // Protects active stack frames from callback-driven destruction, not threads.
    busy: bool = false,
    attachments: [2]?*Attachment = .{ null, null },
    timers: core.Fifo(Scheduled) = .{},
    next_timer_id: u64 = 1,

    /// Borrows a mux with capacity for LINK and TUN. Its I/O callbacks belong
    /// to this looper until destroy(); the caller retains the mux and wake source.
    pub fn create(
        allocator: std.mem.Allocator,
        options: helpers.Options,
    ) helpers.InitError!*PosixLooper {
        const mux = options.mux orelse return error.MuxFailure;
        const self = try allocator.create(PosixLooper);
        self.* = .{ .allocator = allocator, .options = options };
        io_c.pp_mux_set_on_readable(mux, onReadable, self);
        io_c.pp_mux_set_on_writable(mux, onWritable, self);
        return self;
    }

    pub fn destroy(self: *PosixLooper) void {
        if (self.busy) @panic("Looper.destroy() must run outside callbacks");
        self.busy = true;
        self.clear();
        io_c.pp_mux_set_on_readable(self.options.mux, null, null);
        io_c.pp_mux_set_on_writable(self.options.mux, null, null);
        self.allocator.destroy(self);
    }

    /// Zero polls without blocking; null waits for I/O, wake, or the next deadline.
    /// Otherwise waits at most max_wait_ms. Returns false after stop/fatal failure.
    /// Wake readiness returns control to the caller; pp_mux_wait consumes the
    /// mux wake signal. The caller must keep the borrowed mux valid.
    /// Tasks scheduled by callbacks become eligible on the next iteration.
    pub fn loopOnce(self: *PosixLooper, max_wait_ms: ?u32, failure: *?io.Failure) bool {
        if (self.busy) @panic("Looper.loopOnce() must not be reentrant");
        if (self.stopped) return false;
        self.busy = true;
        defer self.busy = false;

        if (self.waitReady(max_wait_ms)) |code| {
            self.clear();
            failure.* = .{ .wait = code };
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
        for (self.attachments) |maybe_attachment| {
            const attachment = maybe_attachment orelse continue;
            if (attachment.read_retry) |deadline| {
                if (deadline <= now) attachment.read_retry = null;
            }
            if (attachment.write_retry) |deadline| {
                if (deadline <= now) {
                    attachment.write_retry = null;
                    attachment.write_ready = true;
                }
            }
        }

        // Drain outgoing batches before accepting more input. Read TUN first.
        for ([_]io.Side{ .link, .tun }) |tag| {
            const attachment = self.attachments[@intFromEnum(tag)] orelse continue;
            if (attachment.write_ready and attachment.write_retry == null) {
                if (self.processWrite(attachment)) |internal_failure| {
                    self.removeSide(tag, internal_failure);
                    failure.* = internal_failure;
                    return true;
                }
            }
        }
        for ([_]io.Side{ .tun, .link }) |tag| {
            const attachment = self.attachments[@intFromEnum(tag)] orelse continue;
            if (attachment.read_ready and attachment.reading and attachment.read_retry == null) {
                if (self.processRead(attachment)) |internal_failure| {
                    self.removeSide(tag, internal_failure);
                    failure.* = internal_failure;
                    return true;
                }
            }
        }
        return true;
    }

    /// Cancels pending work and cleans up attachments.
    pub fn stop(self: *PosixLooper) error{ReentrantCall}!void {
        if (self.busy) return error.ReentrantCall;
        if (self.stopped) return;
        self.busy = true;
        defer self.busy = false;
        self.clear();
    }

    /// Failed replacement preserves the old task. The token's address is not retained.
    pub fn scheduleTimer(self: *PosixLooper, timer: *io.Timer, delay_ms: u64, task: io.TimedTask) helpers.SubmissionError!void {
        if (self.stopped) return error.LooperUnavailable;
        const node = try self.allocator.create(Scheduled);
        node.* = .{ .id = self.next_timer_id, .deadline_ns = deadlineAfter(delay_ms), .task = task };
        self.next_timer_id +%= 1;
        if (self.next_timer_id == 0) self.next_timer_id = 1;
        self.cancelTimer(timer);
        self.timers.append(node);
        timer.id = node.id;
    }

    pub fn cancelTimer(self: *PosixLooper, timer: *io.Timer) void {
        const id = timer.id orelse return;
        if (self.timers.removeWhere(id, Scheduled.hasId)) |node| self.allocator.destroy(node);
        timer.id = null;
    }

    /// Native I/O ownership transfers only after successful attachment.
    pub fn attach(self: *PosixLooper, arguments: helpers.AttachArguments) helpers.AttachError!void {
        if (self.busy) return error.ReentrantCall;
        if (self.stopped) return error.LooperUnavailable;
        const tag = std.meta.activeTag(arguments.pair);
        const buffer_size = switch (tag) {
            .link => self.options.link_buf_size,
            .tun => self.options.tun_buf_size,
        };
        if (buffer_size == 0 or self.options.max_read_count == 0 or self.options.max_read_size == 0) return error.InvalidBuffers;
        const slot = &self.attachments[@intFromEnum(tag)];
        if (slot.* != null) return error.SideAlreadyAttached;
        const descriptor = switch (arguments.pair) {
            inline else => |value| value,
        };
        if (descriptor.fd < 0 or descriptor.fd == io_c.pp_mux_wake_descriptor(self.options.mux) or
            (descriptor.io.isUnconnected() and tag != .link)) return error.MuxFailure;
        for (self.attachments) |other| {
            if (other) |attachment| if (attachment.fd == descriptor.fd) return error.MuxFailure;
        }
        if (!io_c.pp_mux_add(self.options.mux, descriptor.fd)) return error.MuxFailure;
        errdefer _ = io_c.pp_mux_delete(self.options.mux, descriptor.fd);
        slot.* = try Attachment.create(self.allocator, tag, descriptor, arguments, self.options.max_read_count, buffer_size);
    }

    pub fn detach(self: *PosixLooper, tag: io.Side) helpers.DetachError!void {
        if (self.busy) return error.ReentrantCall;
        if (self.stopped) return error.LooperUnavailable;
        self.busy = true;
        defer self.busy = false;
        self.removeSide(tag, null);
    }

    pub fn isAttached(self: *const PosixLooper, tag: io.Side) bool {
        return self.attachments[@intFromEnum(tag)] != null;
    }

    pub fn resumeReading(self: *PosixLooper, tag: io.Side) error{LooperUnavailable}!void {
        if (self.stopped) return error.LooperUnavailable;
        if (self.attachments[@intFromEnum(tag)]) |attachment| {
            attachment.reading = true;
            attachment.read_retry = null;
        }
    }

    /// Copies the complete batch, or leaves the queue unchanged on allocation failure.
    pub fn write(self: *PosixLooper, packets: io.Packets, tag: io.Side, destination: ?io.SocketAddress) helpers.WriteError!void {
        if (packets.len == 0) return;
        if (self.stopped) return error.LooperUnavailable;
        const attachment = self.attachments[@intFromEnum(tag)] orelse return error.SideNotAttached;
        if (attachment.native_io.isUnconnected() and destination == null) return error.MissingDestination;
        try attachment.write_queue.append(packets, destination);
        if (attachment.write_retry == null) attachment.write_ready = true;
    }

    /// Makes one nonblocking drain attempt without invoking read, timer or failure callbacks.
    /// The caller may detach afterwards even if writes fail or remain blocked.
    pub fn flushWrites(self: *PosixLooper, tag: io.Side) helpers.DetachError!?io.Failure {
        if (self.busy) return error.ReentrantCall;
        if (self.stopped) return error.LooperUnavailable;
        self.busy = true;
        defer self.busy = false;
        const attachment = self.attachments[@intFromEnum(tag)] orelse return null;
        return self.processWrite(attachment);
    }

    fn processWrite(self: *PosixLooper, attachment: *Attachment) ?io.Failure {
        defer attachment.write_ready = false;
        while (attachment.write_queue.pending()) |pending| {
            const written = attachment.native_io.writePacket(pending.data, pending.offset, pending.address) catch |err| {
                switch (err) {
                    error.WouldBlock => return null,
                    error.Backpressure => {
                        const deadline = deadlineAfter(retry_delay_ms);
                        attachment.write_retry = deadline;
                        const opposite: io.Side = if (attachment.side == .link) .tun else .link;
                        if (self.attachments[@intFromEnum(opposite)]) |other| {
                            if (other.reading and other.read_retry == null) other.read_retry = deadline;
                        }
                        return null;
                    },
                    else => {
                        if (err == error.DatagramDropped) {
                            _ = attachment.write_queue.advance(pending.data.len - pending.offset);
                            continue;
                        }
                        return attachment.ioFailure(err);
                    },
                }
            };
            if (!attachment.write_queue.advance(written) and written == 0) {
                // A zero-byte stream write must not monopolize this iteration.
                return null;
            }
        }
        return null;
    }

    fn processRead(self: *PosixLooper, attachment: *Attachment) ?io.Failure {
        const result = attachment.readPackets(self.options.max_read_size);
        defer @memset(attachment.read_packets[0..result.count], &.{});
        var action: io.ReadAction = .keep;
        if (result.count > 0) {
            if (attachment.on_read) |callback| {
                const addresses = if (attachment.read_addresses) |values| values[0..result.count] else null;
                action = callback.call(attachment.read_packets[0..result.count], addresses) catch |err| return .{ .user = err };
            }
        }
        if (result.failure) |err| return attachment.ioFailure(err);
        if (action == .pause) attachment.reading = false;
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
        for (self.attachments) |maybe_attachment| {
            const attachment = maybe_attachment orelse continue;
            attachment.read_ready = false;
            if (attachment.read_retry) |ns| deadline_ns = @min(deadline_ns, ns);
            if (attachment.write_retry) |ns| deadline_ns = @min(deadline_ns, ns);
            if (attachment.write_ready and attachment.write_retry == null) deadline_ns = now_ns;
            _ = io_c.pp_mux_set_read(self.options.mux, attachment.fd, attachment.reading and attachment.read_retry == null);
            _ = io_c.pp_mux_set_write(self.options.mux, attachment.fd, attachment.write_queue.pending() != null and attachment.write_retry == null);
        }
        const remaining_ns = deadline_ns -| now_ns;
        const timeout_ms: c_int = if (deadline_ns == std.math.maxInt(u64)) -1 else @intCast(@min(std.math.maxInt(c_int), remaining_ns / std.time.ns_per_ms + @intFromBool(remaining_ns % std.time.ns_per_ms != 0)));
        var code: c_int = 0;
        if (io_c.pp_mux_wait(self.options.mux, timeout_ms, &code) < 0) return code;
        return null;
    }

    fn onReadable(context: ?*anyopaque, fd: io.FileDescriptor) callconv(.c) void {
        const self: *PosixLooper = @ptrCast(@alignCast(context.?));
        for (self.attachments) |maybe_attachment| {
            if (maybe_attachment) |attachment| if (attachment.fd == fd) {
                attachment.read_ready = true;
            };
        }
    }

    fn onWritable(context: ?*anyopaque, fd: io.FileDescriptor) callconv(.c) void {
        const self: *PosixLooper = @ptrCast(@alignCast(context.?));
        for (self.attachments) |maybe_attachment| {
            if (maybe_attachment) |attachment| if (attachment.fd == fd) {
                attachment.write_ready = true;
            };
        }
    }

    // All callers hold the reentrancy guard, including while cancelling writes.
    fn removeSide(self: *PosixLooper, tag: io.Side, failure: ?io.Failure) void {
        const slot = &self.attachments[@intFromEnum(tag)];
        const attachment = slot.* orelse return;
        slot.* = null;
        _ = io_c.pp_mux_delete(self.options.mux, attachment.fd);
        if (failure) |reason| if (attachment.on_failure) |callback| callback.call(reason);
        attachment.native_io.cleanup();
        attachment.write_queue.deinit();
        self.allocator.free(attachment.read_bytes);
        self.allocator.free(attachment.read_packets);
        if (attachment.read_addresses) |addresses| self.allocator.free(addresses);
        self.allocator.destroy(attachment);
    }

    fn clear(self: *PosixLooper) void {
        self.stopped = true;
        while (self.timers.take()) |node| self.allocator.destroy(node);
        self.removeSide(.link, null);
        self.removeSide(.tun, null);
    }

    const Attachment = struct {
        side: io.Side,
        fd: io.FileDescriptor,
        native_io: io_posix.POSIXInterface,
        on_read: ?helpers.OnRead,
        on_failure: ?helpers.OnFailure,
        read_bytes: []u8,
        buffer_size: usize,
        read_packets: []io.Packet,
        read_addresses: ?[]io.SocketAddress,
        write_queue: helpers.WriteQueue,
        reading: bool = true,
        read_ready: bool = false,
        write_ready: bool = false,
        read_retry: ?u64 = null,
        write_retry: ?u64 = null,

        fn create(allocator: std.mem.Allocator, side: io.Side, descriptor: io_posix.POSIXDescriptor, arguments: helpers.AttachArguments, max_read_count: usize, buffer_size: usize) std.mem.Allocator.Error!*Attachment {
            // Keep each side's pool within 1 MiB, with at least one full-size packet.
            const count = @min(max_read_count, @max(1, 1024 * 1024 / buffer_size));
            const size = std.math.mul(usize, count, buffer_size) catch return error.OutOfMemory;
            const bytes = try allocator.alloc(u8, size);
            errdefer allocator.free(bytes);
            const packets = try allocator.alloc(io.Packet, count);
            errdefer allocator.free(packets);
            const addresses = if (descriptor.io.isUnconnected()) try allocator.alloc(io.SocketAddress, count) else null;
            errdefer if (addresses) |values| allocator.free(values);
            const self = try allocator.create(Attachment);
            self.* = .{
                .side = side,
                .fd = descriptor.fd,
                .native_io = descriptor.io,
                .on_read = arguments.on_read,
                .on_failure = arguments.on_failure,
                .read_bytes = bytes,
                .buffer_size = buffer_size,
                .read_packets = packets,
                .read_addresses = addresses,
                .write_queue = helpers.WriteQueue.init(allocator),
            };
            return self;
        }

        const ReadResult = struct {
            count: usize = 0,
            failure: ?io.Error = null,
        };

        fn readPackets(self: *Attachment, max_size: usize) ReadResult {
            var result = ReadResult{};
            var size: usize = 0;
            // Discarded datagrams also count against the attempt budget.
            for (0..self.read_packets.len) |_| {
                const start = result.count * self.buffer_size;
                const buffer = self.read_bytes[start..][0..self.buffer_size];
                var address: io.SocketAddress = undefined;
                const count = self.native_io.readPacket(buffer, &address) catch |err| {
                    if (err == error.DatagramDropped) continue;
                    if (err != error.WouldBlock) result.failure = err;
                    break;
                } orelse break;

                self.read_packets[result.count] = buffer[0..count];
                if (self.read_addresses) |addresses| addresses[result.count] = address;
                result.count += 1;
                size += count;
                if (size >= max_size) break;
            }
            return result;
        }

        fn ioFailure(self: *const Attachment, cause: io.Error) io.Failure {
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
