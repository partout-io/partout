// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Caller-driven, synchronous POSIX I/O loop. This experimental implementation
//! is not wired into the daemon. It creates no threads and performs no locking.
//! The caller must serialize all access, but no particular thread is required.
//! Keep the object at a stable address after start(). Callbacks execute inline;
//! they may submit writes, resume reads, and manage timers, but must not attach,
//! detach, stop, destroy, or recursively call loopOnce(). Borrowed packet storage
//! must remain valid until its completion callback. Pending writes are cancelled
//! on detach/stop/destroy; synchronous control does not imply blocking writes.

const std = @import("std");
const core = @import("../core/exports.zig");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const io_posix = @import("io_posix.zig");
const io_c = io.io_c;
const log = core.logging;

const monotonicNs = core.monotonicNs;

pub const PosixLooper = struct {
    const number_of_descriptors = 2;
    const no_buf_retry_delay_ms = 10;
    pub const StartError = std.mem.Allocator.Error || error{AlreadyStarted};
    const State = enum { idle, started, stopped };
    const ProcessOutcome = union(enum) {
        ok,
        side_failure: struct { side: io.Side, failure: helpers.Failure },
        fatal: helpers.Failure,
    };
    const Scheduled = struct {
        id: u64,
        deadline_ns: u64,
        task: helpers.TimedTask,
        next: ?*Scheduled = null,
        ready: bool = false,
    };

    allocator: std.mem.Allocator,
    options: helpers.Options,
    state: State = .idle,
    callback_depth: usize = 0,
    timers: core.Fifo(Scheduled) = .{},
    next_timer_id: u64 = 1,
    mux: io_c.pp_mux,
    fd_set: ?DescriptorSet = null,
    link: ?*SideIO = null,
    tun: ?*SideIO = null,
    read_retries: [2]?u64 = .{ null, null },
    write_retries: [2]?u64 = .{ null, null },

    pub fn create(allocator: std.mem.Allocator, options: helpers.Options) helpers.InitError!*PosixLooper {
        const mux = io_c.pp_mux_create(number_of_descriptors) orelse return error.MuxFailure;
        errdefer io_c.pp_mux_free(mux);
        const self = try allocator.create(PosixLooper);
        self.* = .{ .allocator = allocator, .options = options, .mux = mux };
        return self;
    }

    pub fn destroy(self: *PosixLooper) void {
        if (self.callback_depth > 0) @panic("Looper.destroy() must run outside callbacks");
        self.state = .stopped;
        self.cancelAllTimers();
        self.cleanupSides();
        if (self.fd_set) |*fd_set| fd_set.deinit();
        io_c.pp_mux_free(self.mux);
        self.allocator.destroy(self);
    }

    /// Initializes I/O bookkeeping only. The caller drives subsequent iterations.
    pub fn start(self: *PosixLooper) StartError!void {
        if (self.state != .idle) return error.AlreadyStarted;
        self.fd_set = try DescriptorSet.init(self.allocator);
        self.state = .started;
    }

    /// Waits at most max_wait_ms (null means indefinitely), bounded further by
    /// the next timer/retry deadline. Zero polls without blocking. Runs ready
    /// timers and I/O inline. Returns false before start or after stop/fatal failure.
    /// Timers scheduled by callbacks are eligible on the next iteration.
    pub fn loopOnce(self: *PosixLooper, max_wait_ms: ?u32) bool {
        if (self.callback_depth > 0) @panic("Looper.loopOnce() must not be reentrant");
        if (self.state != .started) return false;
        self.callback_depth += 1;
        defer self.callback_depth -= 1;
        const fd_set = &self.fd_set.?;
        fd_set.resetReadable();
        if (self.waitReady(max_wait_ms, fd_set)) |code| {
            self.finish(.{ .wait = code });
            return false;
        }
        self.runTimers();
        self.runRetries(fd_set) catch |err| {
            self.finish(.{ .system = err });
            return false;
        };
        if (fd_set.allocation_failed) {
            self.finish(.{ .system = error.OutOfMemory });
            return false;
        }
        switch (self.process(fd_set)) {
            .ok => {},
            .side_failure => |item| self.detachImmediately(item.side, item.failure),
            .fatal => |failure| {
                self.finish(failure);
                return false;
            },
        }
        return true;
    }

    /// Cancels pending writes and timers, cleans attached sides, and calls on_finish.
    /// Calling before start or after stop is harmless. Resources remain until destroy.
    pub fn stop(self: *PosixLooper) helpers.StopError!void {
        if (self.callback_depth > 0) return error.ReentrantCall;
        if (self.state == .started) self.finish(null);
    }

    /// Replaces a delayed task. Its callback runs only when loopOnce() is driven.
    /// The token's address is never retained. Failed replacement preserves the old task.
    pub fn scheduleReplacing(self: *PosixLooper, timer: *helpers.Timer, delay_ms: u64, task: helpers.TimedTask) helpers.SubmissionError!void {
        if (self.state != .started) return error.LooperUnavailable;
        const node = try self.allocator.create(Scheduled);
        const id = self.next_timer_id;
        self.next_timer_id +%= 1;
        if (self.next_timer_id == 0) self.next_timer_id = 1;
        node.* = .{ .id = id, .deadline_ns = deadlineAfter(delay_ms), .task = task };
        self.cancelTimer(timer);
        self.timers.append(node);
        timer.id = id;
    }

    pub fn cancelTimer(self: *PosixLooper, timer: *helpers.Timer) void {
        const id = timer.id orelse return;
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next) {
            if (node.id == id) {
                std.debug.assert(self.timers.remove(node));
                self.allocator.destroy(node);
                break;
            }
        }
        timer.id = null;
    }

    pub fn detach(self: *PosixLooper, side: io.Side) helpers.DetachError!void {
        if (self.callback_depth > 0) return error.ReentrantCall;
        if (self.state != .started) return error.LooperUnavailable;
        if (self.takeSideIO(side)) |side_io| self.destroyDetachedSideIO(side_io);
    }

    pub fn isLinkAttached(self: *const PosixLooper) bool {
        return self.link != null;
    }
    pub fn isTunAttached(self: *const PosixLooper) bool {
        return self.tun != null;
    }

    pub fn resumeReading(self: *PosixLooper, side: io.Side) (error{LooperUnavailable} || io.Error)!void {
        if (self.state != .started) return error.LooperUnavailable;
        self.read_retries[sideIndex(side)] = null;
        if (self.sideIO(side)) |side_io| try side_io.setRead(self.mux, true);
    }

    /// Borrows the batch until completion. Rejection never invokes completion.
    pub fn writeQueued(self: *PosixLooper, packets: helpers.Packets, side: io.Side, destination: ?io.SocketAddress, completion: helpers.OnWriteComplete) (helpers.WriteError || io.Error)!void {
        if (packets.len == 0) return error.InvalidBuffers;
        if (self.state != .started) return error.LooperUnavailable;
        const current = self.sideIO(side) orelse return error.SideNotAttached;
        if (current.native_io.isUnconnected() and destination == null) return error.MissingDestination;
        const request = try self.allocator.create(helpers.WriteRequest);
        errdefer self.allocator.destroy(request);
        // Backpressure retries stay suspended until their deadline, even if a
        // callback submits another batch in the meantime.
        if (self.write_retries[sideIndex(side)] == null) {
            try current.setWrite(self.mux, true);
            self.fd_set.?.insertWritable(current.fd);
        }
        request.* = .{ .packets = packets, .destination = destination, .completion = completion };
        current.write_queue.append(request);
    }

    pub fn attach(
        self: *PosixLooper,
        arguments: helpers.AttachArguments,
    ) helpers.AttachError!void {
        if (self.callback_depth > 0) return error.ReentrantCall;
        if (self.state != .started) return error.LooperUnavailable;
        if (arguments.read_buffers == null or self.options.max_read_count == 0)
            return error.InvalidBuffers;

        const side = std.meta.activeTag(arguments.pair);
        if (self.sideIO(side) != null) {
            return error.SideAlreadyAttached;
        }
        const descriptor = switch (arguments.pair) {
            .link => |value| value,
            .tun => |value| value,
        };
        if (descriptor.io.isUnconnected() and side != .link) {
            return error.MuxFailure;
        }
        if (!io_c.pp_mux_add(self.mux, descriptor.fd)) {
            log.writef(.err, "Unable to attach {} (fd={any})", .{ side, descriptor.fd });
            return error.MuxFailure;
        }
        log.writef(.info, "Attach {} (fd={any})", .{ side, descriptor.fd });

        const side_io = SideIO.create(
            self.allocator,
            side,
            descriptor,
            arguments,
            self.options.max_read_count,
        ) catch |err| {
            _ = io_c.pp_mux_delete(self.mux, descriptor.fd);
            return err;
        };
        side_io.syncEventMask() catch {
            log.writef(.err, "Unable to retain {}", .{side});
            _ = io_c.pp_mux_delete(self.mux, descriptor.fd);
            side_io.destroyStorage(self.allocator);
            return error.MuxFailure;
        };

        self.setSideIO(side, side_io);
    }

    pub fn writeOutOfBand(
        self: *PosixLooper,
        packets: helpers.Packets,
        side: io.Side,
        destination: ?io.SocketAddress,
    ) helpers.WriteOOBError!void {
        if (self.state != .started) {
            return error.LooperUnavailable;
        }
        const side_io = self.sideIO(side) orelse {
            log.writef(.err, "Ignoring {} packets, not attached", .{side});
            return;
        };

        if (side_io.native_io.isUnconnected() and destination == null) {
            return error.MissingDestination;
        }

        for (packets) |packet| {
            const written = side_io.native_io.writePacket(
                packet,
                0,
                destination,
            ) catch |err| {
                log.writef(.err, "{} write failed: {s}", .{
                    side,
                    @errorName(err),
                });
                return err;
            };
            if (written != packet.len) {
                log.writef(.err, "Incomplete {} write ({}/{})", .{
                    side,
                    written,
                    packet.len,
                });
                return error.WriteIncomplete;
            }
        }
    }

    fn process(self: *PosixLooper, fd_set: *DescriptorSet) ProcessOutcome {
        if (self.link) |link| {
            if (fd_set.isReadable(link.fd) or fd_set.isWritable(link.fd)) {
                link.resetEvents() catch |err| return .{ .fatal = .{ .system = err } };
            }
        }
        if (self.tun) |tun| {
            if (fd_set.isReadable(tun.fd) or fd_set.isWritable(tun.fd)) {
                tun.resetEvents() catch |err| return .{ .fatal = .{ .system = err } };
            }
        }

        if (self.link) |link| {
            if (fd_set.isWritable(link.fd)) {
                const outcome = self.processWrite(link, self.tun, fd_set);
                if (outcome != .ok) return outcome;
            }
        }
        if (self.tun) |tun| {
            if (fd_set.isWritable(tun.fd)) {
                const outcome = self.processWrite(tun, self.link, fd_set);
                if (outcome != .ok) return outcome;
            }
        }
        if (self.tun) |tun| {
            if (fd_set.isReadable(tun.fd)) {
                const outcome = self.processRead(tun);
                if (outcome != .ok) return outcome;
            }
        }
        if (self.link) |link| {
            if (fd_set.isReadable(link.fd)) return self.processRead(link);
        }
        return .ok;
    }

    fn processWrite(
        self: *PosixLooper,
        side_io: *SideIO,
        opposite: ?*SideIO,
        fd_set: *DescriptorSet,
    ) ProcessOutcome {
        var watch_writes = false;
        while (side_io.write_queue.head) |pending_req| {
            const pending_write = pending_req.pendingWrite();
            const written = side_io.native_io.writePacket(
                pending_write.data,
                pending_write.offset,
                pending_write.address,
            ) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        watch_writes = true;
                        break;
                    },
                    error.Backpressure => {
                        if (opposite) |other| {
                            self.suspendRead(other, fd_set) catch |suspend_err| {
                                return .{ .fatal = .{ .system = suspend_err } };
                            };
                            self.scheduleReadRetry(other);
                        }
                        self.scheduleWriteRetry(side_io);
                        watch_writes = false;
                        break;
                    },
                    else => {
                        const failed_req = side_io.write_queue.take();
                        std.debug.assert(failed_req == pending_req);

                        pending_req.complete(self.allocator, err);
                        if (err == error.DatagramDropped) continue;
                        return .{ .side_failure = .{
                            .side = side_io.side,
                            .failure = side_io.ioFailure(err),
                        } };
                    },
                }
            };

            const is_complete = pending_req.advance(written);
            if (is_complete) {
                const removed_req = side_io.write_queue.take();
                std.debug.assert(removed_req == pending_req);
            }

            watch_writes = written != pending_write.data.len - pending_write.offset;
            if (is_complete) {
                pending_req.complete(self.allocator, null);
            }
        }

        side_io.setWrite(self.mux, watch_writes) catch |err| {
            return .{ .fatal = .{ .system = err } };
        };
        fd_set.removeWritable(side_io.fd);
        return .ok;
    }

    fn processRead(self: *PosixLooper, side_io: *SideIO) ProcessOutcome {
        if (!side_io.is_reading) return .ok;

        // Borrow storage only for this read attempt and the on_read callback.
        const buffers = side_io.acquireReadBuffers();
        const result = side_io.readPackets(buffers, self.options.max_read_size);
        defer side_io.releaseReadBuffers(buffers, result);

        var action: helpers.ReadAction = if (buffers.len == 0) .pause else .keep;
        if (result.count > 0) {
            action = side_io.notifyRead(result.count) catch |err| return .{
                .side_failure = .{
                    .side = side_io.side,
                    .failure = .{ .user = err },
                },
            };
        }
        if (result.failure) |err| {
            return .{
                .side_failure = .{
                    .side = side_io.side,
                    .failure = if (err == error.InvalidBuffers)
                        .{ .user = err }
                    else
                        side_io.ioFailure(@errorCast(err)),
                },
            };
        }
        if (action == .pause) {
            side_io.setRead(self.mux, false) catch |err| return .{
                .fatal = .{ .system = err },
            };
        }
        return .ok;
    }

    fn suspendRead(
        self: *PosixLooper,
        side_io: *SideIO,
        fd_set: *DescriptorSet,
    ) io.Error!void {
        try side_io.setRead(self.mux, false);
        fd_set.removeReadable(side_io.fd);
    }

    fn deadlineAfter(delay_ms: u64) u64 {
        return monotonicNs() +| (delay_ms *| std.time.ns_per_ms);
    }

    // The existing mux API waits indefinitely. Poll locally to support bounded
    // iterations and deadlines without changing the production mux/looper API.
    fn waitReady(self: *PosixLooper, max_wait_ms: ?u32, fd_set: *DescriptorSet) ?c_int {
        var timeout_ns: ?u64 = if (max_wait_ms) |ms| @as(u64, ms) * std.time.ns_per_ms else null;
        const now = monotonicNs();
        var timer = self.timers.head;
        while (timer) |node| : (timer = node.next) boundTimeout(&timeout_ns, node.deadline_ns -| now);
        for (self.read_retries ++ self.write_retries) |deadline| {
            if (deadline) |ns| boundTimeout(&timeout_ns, ns -| now);
        }
        if (fd_set.writable.items.len > 0) timeout_ns = 0;
        const timeout: c_int = if (timeout_ns) |ns|
            @intCast(@min(std.math.maxInt(c_int), ns / std.time.ns_per_ms + @intFromBool(ns % std.time.ns_per_ms != 0)))
        else
            -1;
        var fds: [number_of_descriptors]std.c.pollfd = undefined;
        var count: usize = 0;
        for ([_]?*SideIO{ self.link, self.tun }) |maybe_side| {
            if (maybe_side) |side_io| {
                if (!side_io.is_reading and !side_io.is_writing) continue;
                fds[count] = .{ .fd = side_io.fd, .events = (if (side_io.is_reading) @as(i16, std.c.POLL.IN) else 0) |
                    (if (side_io.is_writing) @as(i16, std.c.POLL.OUT) else 0), .revents = 0 };
                count += 1;
            }
        }
        const result = std.c.poll(&fds, @intCast(count), timeout);
        const err = std.posix.errno(result);
        // Return control on interruption; the next iteration recomputes deadlines.
        if (err == .INTR) return null;
        if (err != .SUCCESS) return @intFromEnum(err);
        for (fds[0..count]) |fd| {
            const failed = fd.revents & (std.c.POLL.ERR | std.c.POLL.HUP | std.c.POLL.NVAL) != 0;
            if (fd.events & std.c.POLL.IN != 0 and (failed or fd.revents & std.c.POLL.IN != 0)) fd_set.insertReadable(fd.fd);
            if (fd.events & std.c.POLL.OUT != 0 and (failed or fd.revents & std.c.POLL.OUT != 0)) fd_set.insertWritable(fd.fd);
        }
        return null;
    }

    fn boundTimeout(timeout: *?u64, ns: u64) void {
        timeout.* = if (timeout.*) |previous| @min(previous, ns) else ns;
    }

    fn runTimers(self: *PosixLooper) void {
        const now = monotonicNs();
        // Mark ready tasks so callbacks may replace/cancel timers safely, and
        // newly scheduled zero-delay tasks cannot monopolize this iteration.
        var pending = self.timers.head;
        while (pending) |node| : (pending = node.next) node.ready = node.deadline_ns <= now;
        pending = self.timers.head;
        while (pending) |node| {
            if (node.ready) {
                std.debug.assert(self.timers.remove(node));
                const task = node.task;
                self.allocator.destroy(node);
                task.call();
                // The callback may have removed or replaced any pending node.
                pending = self.timers.head;
            } else pending = node.next;
        }
    }

    fn runRetries(self: *PosixLooper, fd_set: *DescriptorSet) io.Error!void {
        const now = monotonicNs();
        for ([_]io.Side{ .link, .tun }) |side| {
            const index = sideIndex(side);
            if (self.read_retries[index]) |deadline| {
                if (deadline <= now) {
                    self.read_retries[index] = null;
                    if (self.sideIO(side)) |side_io| try side_io.setRead(self.mux, true);
                }
            }
            if (self.write_retries[index]) |deadline| {
                if (deadline <= now) {
                    self.write_retries[index] = null;
                    if (self.sideIO(side)) |side_io| {
                        try side_io.setWrite(self.mux, true);
                        fd_set.insertWritable(side_io.fd);
                    }
                }
            }
        }
    }

    fn scheduleReadRetry(self: *PosixLooper, side_io: *const SideIO) void {
        const index = sideIndex(side_io.side);
        if (self.read_retries[index] == null) self.read_retries[index] = deadlineAfter(no_buf_retry_delay_ms);
    }

    fn scheduleWriteRetry(self: *PosixLooper, side_io: *const SideIO) void {
        const index = sideIndex(side_io.side);
        if (self.write_retries[index] == null) self.write_retries[index] = deadlineAfter(no_buf_retry_delay_ms);
    }

    fn detachImmediately(self: *PosixLooper, side: io.Side, failure: helpers.Failure) void {
        const side_io = self.takeSideIO(side) orelse return;
        const on_failure = side_io.on_failure;
        if (on_failure) |callback| callback.call(failure);
        self.destroyDetachedSideIO(side_io);
    }

    fn finish(self: *PosixLooper, failure: ?helpers.Failure) void {
        if (self.state == .stopped) return;
        self.state = .stopped;
        self.cancelAllTimers();
        self.cleanupSides();
        self.callback_depth += 1;
        defer self.callback_depth -= 1;
        self.options.on_finish.call(failure);
    }

    fn takeSideIO(self: *PosixLooper, side: io.Side) ?*SideIO {
        const side_io = self.sideIO(side) orelse return null;
        self.setSideIO(side, null);
        self.read_retries[sideIndex(side)] = null;
        self.write_retries[sideIndex(side)] = null;
        if (self.fd_set) |*fd_set| {
            fd_set.removeReadable(side_io.fd);
            fd_set.removeWritable(side_io.fd);
        }
        return side_io;
    }

    fn destroyDetachedSideIO(self: *PosixLooper, side_io: *SideIO) void {
        self.callback_depth += 1;
        defer self.callback_depth -= 1;
        if (side_io.detachFromMux(self.mux)) side_io.cleanupNative();
        side_io.destroyStorage(self.allocator);
    }

    fn cleanupSides(self: *PosixLooper) void {
        if (self.takeSideIO(.link)) |side_io| self.destroyDetachedSideIO(side_io);
        if (self.takeSideIO(.tun)) |side_io| self.destroyDetachedSideIO(side_io);
    }

    fn cancelAllTimers(self: *PosixLooper) void {
        while (self.timers.take()) |node| self.allocator.destroy(node);
    }

    fn sideIO(self: *const PosixLooper, side: io.Side) ?*SideIO {
        return switch (side) {
            .link => self.link,
            .tun => self.tun,
        };
    }
    fn setSideIO(self: *PosixLooper, side: io.Side, side_io: ?*SideIO) void {
        switch (side) {
            .link => self.link = side_io,
            .tun => self.tun = side_io,
        }
    }
    fn sideIndex(side: io.Side) usize {
        return switch (side) {
            .link => 0,
            .tun => 1,
        };
    }

    const SideIO = struct {
        // Native I/O.
        side: io.Side,
        fd: io.FileDescriptor,
        native_io: io_posix.POSIXInterface,

        // User callbacks.
        on_read: ?helpers.OnRead,
        on_failure: ?helpers.OnFailure,

        // Borrowed payload provider and owned views for on_read.
        read_buffers: helpers.ReadBuffers,
        read_packets: []helpers.Packet,
        read_addresses: ?[]io.SocketAddress,

        // I/O requests.
        write_queue: core.Fifo(helpers.WriteRequest) = .{},

        // Mux event and cleanup state.
        is_reading: bool,
        is_writing: bool,
        did_cleanup: bool,

        fn create(
            allocator: std.mem.Allocator,
            side: io.Side,
            descriptor: io_posix.POSIXDescriptor,
            arguments: helpers.AttachArguments,
            max_read_count: usize,
        ) std.mem.Allocator.Error!*SideIO {
            const packets = try allocator.alloc(helpers.Packet, max_read_count);
            errdefer allocator.free(packets);
            const addresses = if (descriptor.io.isUnconnected())
                try allocator.alloc(io.SocketAddress, max_read_count)
            else
                null;
            errdefer {
                if (addresses) |values| {
                    allocator.free(values);
                }
            }
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
                .is_reading = true,
                .is_writing = false,
                .did_cleanup = false,
            };
            return self;
        }

        fn destroyStorage(self: *SideIO, allocator: std.mem.Allocator) void {
            allocator.free(self.read_packets);
            if (self.read_addresses) |addresses| {
                allocator.free(addresses);
            }
            while (self.write_queue.take()) |request| {
                request.complete(allocator, error.Cancelled);
            }
            allocator.destroy(self);
        }

        fn acquireReadBuffers(self: *const SideIO) []helpers.ReadBuffer {
            return self.read_buffers.acquire(self.read_buffers.context);
        }

        fn releaseReadBuffers(
            self: *const SideIO,
            buffers: []helpers.ReadBuffer,
            result: helpers.IOResult,
        ) void {
            // Drop borrowed views before the provider can unpin/recycle storage.
            @memset(self.read_packets[0..result.count], &.{});
            self.read_buffers.release(self.read_buffers.context, buffers, result);
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

        fn notifyRead(self: *const SideIO, count: usize) anyerror!helpers.ReadAction {
            const callback = self.on_read orelse return .keep;
            const addresses = if (self.read_addresses) |values|
                values[0..count]
            else
                null;
            return callback.call(self.read_packets[0..count], addresses);
        }

        fn resetEvents(self: *const SideIO) io.Error!void {
            return self.native_io.resetEvents();
        }

        fn setRead(self: *SideIO, mux: io_c.pp_mux, enabled: bool) io.Error!void {
            _ = io_c.pp_mux_set_read(mux, self.fd, enabled);
            self.is_reading = enabled;
            try self.syncEventMask();
        }

        fn setWrite(self: *SideIO, mux: io_c.pp_mux, enabled: bool) io.Error!void {
            _ = io_c.pp_mux_set_write(mux, self.fd, enabled);
            self.is_writing = enabled;
            try self.syncEventMask();
        }

        fn syncEventMask(self: *const SideIO) io.Error!void {
            return self.native_io.setEventMask(self.is_reading, self.is_writing);
        }

        fn detachFromMux(self: *SideIO, mux: io_c.pp_mux) bool {
            if (self.did_cleanup) return false;
            self.did_cleanup = true;
            _ = io_c.pp_mux_delete(mux, self.fd);
            return true;
        }

        fn cleanupNative(self: *const SideIO) void {
            self.native_io.cleanup();
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

    const DescriptorSet = struct {
        allocator: std.mem.Allocator,

        readable: std.ArrayList(io.FileDescriptor),
        writable: std.ArrayList(io.FileDescriptor),

        allocation_failed: bool,

        fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!DescriptorSet {
            var self = DescriptorSet{
                .allocator = allocator,
                .readable = .empty,
                .writable = .empty,
                .allocation_failed = false,
            };
            errdefer self.deinit();
            try self.readable.ensureTotalCapacity(allocator, number_of_descriptors);
            try self.writable.ensureTotalCapacity(allocator, number_of_descriptors);
            return self;
        }

        fn deinit(self: *DescriptorSet) void {
            self.readable.deinit(self.allocator);
            self.writable.deinit(self.allocator);
        }

        fn resetReadable(self: *DescriptorSet) void {
            self.readable.clearRetainingCapacity();
        }

        fn insertReadable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            self.insert(&self.readable, fd) catch {
                self.allocation_failed = true;
            };
        }

        fn insertWritable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            self.insert(&self.writable, fd) catch {
                self.allocation_failed = true;
            };
        }

        fn insert(
            self: *const DescriptorSet,
            list: *std.ArrayList(io.FileDescriptor),
            fd: io.FileDescriptor,
        ) std.mem.Allocator.Error!void {
            if (contains(list.items, fd)) return;
            try list.append(self.allocator, fd);
        }

        fn removeReadable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            remove(&self.readable, fd);
        }

        fn removeWritable(self: *DescriptorSet, fd: io.FileDescriptor) void {
            remove(&self.writable, fd);
        }

        fn isReadable(self: DescriptorSet, fd: io.FileDescriptor) bool {
            return contains(self.readable.items, fd);
        }

        fn isWritable(self: DescriptorSet, fd: io.FileDescriptor) bool {
            return contains(self.writable.items, fd);
        }

        fn contains(list: []const io.FileDescriptor, fd: io.FileDescriptor) bool {
            for (list) |item| {
                if (item == fd) return true;
            }
            return false;
        }

        fn remove(list: *std.ArrayList(io.FileDescriptor), fd: io.FileDescriptor) void {
            for (list.items, 0..) |item, index| {
                if (item == fd) {
                    _ = list.orderedRemove(index);
                    return;
                }
            }
        }
    };
};
