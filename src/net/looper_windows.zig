// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");
const core = @import("../core/exports.zig");

/// WinRT owns receive scheduling. Attachments forward borrowed packet buffers
/// directly on WinRT worker threads; loopOnce does not poll socket readiness.
pub const WindowsLooper = struct {
    allocator: std.mem.Allocator,
    options: helpers.Options,

    stopped: bool = false,
    sides: [2]?*SideIO = .{ null, null },
    mutex: core.Mutex = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        options: helpers.Options,
    ) helpers.InitError!*WindowsLooper {
        const self = try allocator.create(WindowsLooper);
        self.* = .{
            .allocator = allocator,
            .options = options,
        };
        return self;
    }

    pub fn destroy(self: *WindowsLooper) void {
        self.stop() catch unreachable;
        self.mutex.deinit();
        self.allocator.destroy(self);
    }

    pub fn loopOnce(self: *WindowsLooper, _: ?u32, failure: *?io.Failure) bool {
        failure.* = null;
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.stopped;
    }

    pub fn stop(self: *WindowsLooper) helpers.StopError!void {
        self.mutex.lock();
        self.stopped = true;
        self.mutex.unlock();
        try self.detach(.link);
        try self.detach(.tun);
    }

    // FIXME: ###, Windows, Schedule timers on the Windows event loop.
    pub fn scheduleTimer(
        _: *WindowsLooper,
        _: *io.Timer,
        _: u64,
        _: io.TimedTask,
    ) io.SubmissionError!void {
        // @panic("WindowsLooper.scheduleTimer is not implemented");
    }

    // FIXME: ###, Windows, Cancel scheduled Windows timers.
    pub fn cancelTimer(_: *WindowsLooper, _: *io.Timer) void {
        // @panic("WindowsLooper.cancelTimer is not implemented");
    }

    pub fn attach(
        self: *WindowsLooper,
        arguments: helpers.AttachArguments,
    ) helpers.AttachError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.options.max_read_count == 0 or self.options.max_read_size == 0 or
            (if (arguments.pair == .link) self.options.link_buf_size else self.options.tun_buf_size) == 0)
        {
            return error.InvalidBuffers;
        }
        if (self.stopped) return error.LooperUnavailable;
        // TUN is deliberately unsupported by this socket receive bridge.
        const socket = switch (arguments.pair) {
            .link => |socket| socket,
            .tun => return error.LooperUnavailable,
        };
        const slot = &self.sides[@intFromEnum(std.meta.activeTag(arguments.pair))];
        if (slot.* != null) return error.SideAlreadyAttached;
        const side = try self.allocator.create(SideIO);
        errdefer self.allocator.destroy(side);
        side.* = .{ .allocator = self.allocator, .arguments = arguments };
        slot.* = side;
        errdefer slot.* = null;
        try socket.setOnReceive(onReceive, side);
    }

    /// Writes complete before returning, so there is no separate flush queue.
    pub fn write(
        self: *WindowsLooper,
        packets: io.Packets,
        tag: io.Side,
        destination: ?io.SocketAddress,
    ) helpers.WriteError!void {
        if (packets.len == 0) return;
        const side = try self.acquireSide(tag);
        defer side.release();
        const socket = switch (side.arguments.pair) {
            .link => |socket| socket,
            .tun => return error.LooperUnavailable,
        };
        if (socket.unconnected and destination == null) return error.MissingDestination;
        for (packets) |packet| {
            if (side.detached.load(.acquire)) return error.SideNotAttached;
            if (try socket.write(packet, destination)) |failure| {
                // Native callback serialization prevents delivery after detach,
                // including when a failure callback itself detaches this side.
                socket.notifyFailure(failure.io.code.?);
                return;
            }
        }
    }

    /// Socket writes are submitted and completed by write().
    pub fn flushWrites(_: *WindowsLooper, _: io.Side) helpers.DetachError!?io.Failure {
        return null;
    }

    pub fn detach(self: *WindowsLooper, tag: io.Side) helpers.DetachError!void {
        self.mutex.lock();
        const slot = &self.sides[@intFromEnum(tag)];
        const side = slot.* orelse {
            self.mutex.unlock();
            return;
        };
        slot.* = null;
        side.detached.store(true, .release);
        self.mutex.unlock();
        // Never hold the looper lock while draining native callbacks: a consumer
        // may reenter detach. Writers retain the side until their batch exits.
        switch (side.arguments.pair) {
            .link => |socket| {
                socket.setOnReceive(null, null) catch unreachable;
            },
            .tun => unreachable, // No TUN attachment is accepted yet.
        }
        side.release();
    }

    pub fn isAttached(self: *const WindowsLooper, side: io.Side) bool {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        return self.sides[@intFromEnum(side)] != null;
    }

    pub fn resumeReading(self: *WindowsLooper, side: io.Side) io.SubmissionError!void {
        if (side != .link) return error.LooperUnavailable;
        const attachment = self.acquireSide(side) catch return error.LooperUnavailable;
        defer attachment.release();
        // Re-registering must not race with detach clearing the callback.
        try attachment.arguments.pair.link.resumeReading();
    }

    fn acquireSide(self: *WindowsLooper, tag: io.Side) error{ LooperUnavailable, SideNotAttached }!*SideIO {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.LooperUnavailable;
        const side = self.sides[@intFromEnum(tag)] orelse return error.SideNotAttached;
        side.retain();
        return side;
    }

    const SideIO = struct {
        allocator: std.mem.Allocator,
        arguments: helpers.AttachArguments,
        references: std.atomic.Value(usize) = .init(1),
        detached: std.atomic.Value(bool) = .init(false),

        fn retain(self: *SideIO) void {
            _ = self.references.fetchAdd(1, .monotonic);
        }

        fn release(self: *SideIO) void {
            if (self.references.fetchSub(1, .acq_rel) != 1) return;
            switch (self.arguments.pair) {
                .link => |socket| socket.cleanup(),
                .tun => unreachable,
            }
            self.allocator.destroy(self);
        }
    };

    fn onReceive(
        context: ?*anyopaque,
        bytes: [*c]const u8,
        length: usize,
        source: [*c]const io.SocketAddress,
        code: i32,
    ) callconv(.c) bool {
        const self: *SideIO = @ptrCast(@alignCast(context.?));
        self.retain();
        defer self.release();
        if (self.detached.load(.acquire)) return false;
        const arguments = self.arguments;
        const on_read = arguments.on_read;
        const on_failure = arguments.on_failure;
        if (code != 0) {
            if (on_failure) |callback| callback.call(.{ .io = .{
                .side = .link,
                .cause = if (code == 1) error.EndOfStream else error.LibcFailure,
                .code = if (code == 1) null else code,
            } });
            return false;
        }
        const packets = [_]io.Packet{if (length == 0) &.{} else bytes[0..length]};
        const addresses: ?[]const io.SocketAddress = if (source == null) null else source[0..1];
        if (on_read) |callback| {
            const action = callback.call(&packets, addresses) catch |err| {
                if (self.detached.load(.acquire)) return false;
                if (on_failure) |failure| failure.call(.{ .user = err });
                return false;
            };
            return action == .keep and !self.detached.load(.acquire);
        }
        return true;
    }
};
