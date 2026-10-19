// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const io = @import("io.zig");
const log = core.logging;

// FIXME: ###, Abuse of anyerror in callbacks

pub const Options = struct {
    /// Borrowed mux; null is rejected. Keep it alive through looper destruction.
    mux: io.io_c.pp_mux,
    link_buf_size: usize = 64 * 1024,
    tun_buf_size: usize = 64 * 1024,
    max_read_size: usize = 256 * 1024,
    max_read_count: usize = 128,
};

pub const Packet = io.Packet;

pub const Packets = io.Packets;

pub const ReadAction = io.ReadAction;

/// Invoked on read events from either looper side. Payloads and addresses are
/// borrowed until the callback returns. Unconnected UDP supplies one source
/// address per packet, in the same order; connected sockets and TUN supply null.
pub const OnRead = struct {
    context: ?*anyopaque = null,
    callback: *const fn (
        ?*anyopaque,
        Packets,
        ?[]const io.SocketAddress,
    ) anyerror!ReadAction,

    pub fn call(
        self: OnRead,
        packets: Packets,
        addresses: ?[]const io.SocketAddress,
    ) anyerror!ReadAction {
        return self.callback(self.context, packets, addresses);
    }
};

pub const Failure = io.Failure;

/// Invoked on any failure event.
pub const OnFailure = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Failure) void,

    pub fn call(self: OnFailure, failure: Failure) void {
        self.callback(self.context, failure);
    }
};

pub const TimedTask = io.TimedTask;

pub const Timer = io.Timer;

/// The arguments to attach a side of the looper.
pub const AttachArguments = struct {
    pair: io.DescriptorPair,
    /// If absent, incoming data is read and discarded.
    on_read: ?OnRead = null,
    on_failure: ?OnFailure = null,
};

pub const SubmissionError = std.mem.Allocator.Error || error{LooperUnavailable};

pub const InitError = std.mem.Allocator.Error || error{MuxFailure};

pub const AttachError = SubmissionError || error{
    InvalidBuffers,
    MuxFailure,
    SideAlreadyAttached,
    ReentrantCall,
};

pub const DetachError = error{ LooperUnavailable, ReentrantCall };

pub const ResumeReadingError = SubmissionError;

pub const StopError = error{ LooperUnavailable, ReentrantCall };

pub const WriteError = SubmissionError || error{
    SideNotAttached,
    InvalidBuffers,
    MissingDestination,
};

/// Helps storing a pending write without copying the
/// original buffer to a partial buffer.
pub const PendingWrite = struct {
    address: ?io.SocketAddress = null,
    data: []const u8,
    offset: usize,
};

/// A node in `WriteQueue`.
const WriteNode = struct {
    address: ?io.SocketAddress = null,
    data: []u8,
    next: ?*WriteNode = null,
};

/// Owned FIFO of packet buffers with partial consumption of the head packet.
/// The queue is not thread-safe; callers must synchronize access.
pub const WriteQueue = struct {
    allocator: std.mem.Allocator,

    // Owned FIFO and partial head progress.
    packets: core.Fifo(WriteNode) = .{},
    offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator) WriteQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WriteQueue) void {
        destroyList(self.allocator, self.packets.takeAll());
        self.offset = 0;
    }

    /// Copies and appends the entire packet batch, or leaves the queue unchanged.
    pub fn append(
        self: *WriteQueue,
        packets: Packets,
        destination: ?io.SocketAddress,
    ) std.mem.Allocator.Error!void {
        var batch = core.Fifo(WriteNode){};
        errdefer destroyList(self.allocator, batch.takeAll());

        for (packets) |packet| {
            const copy = try self.allocator.dupe(u8, packet);
            errdefer self.allocator.free(copy);
            const node = try self.allocator.create(WriteNode);
            node.* = .{ .data = copy, .address = destination };
            batch.append(node);
        }
        self.packets.appendQueue(&batch);
    }

    /// Returns a borrowed view of the head packet and its current offset.
    pub fn pending(self: *const WriteQueue) ?PendingWrite {
        const first = self.packets.head orelse return null;
        return .{
            .data = first.data,
            .address = first.address,
            .offset = self.offset,
        };
    }

    /// Advances the head packet and returns whether it was fully consumed.
    pub fn advance(self: *WriteQueue, written: usize) bool {
        const first = self.packets.head orelse {
            log.writeAndFailDebug("Ignoring advance on an empty WriteQueue");
            return true;
        };
        const remaining = first.data.len - self.offset;
        if (written > remaining)
            @panic("WriteQueue cannot advance past the pending packet");
        if (written < remaining) {
            self.offset += written;
            return false;
        }

        _ = self.packets.take();
        self.offset = 0;
        self.allocator.free(first.data);
        self.allocator.destroy(first);
        return true;
    }

    fn destroyList(allocator: std.mem.Allocator, head: ?*WriteNode) void {
        var current = head;
        while (current) |node| {
            const next = node.next;
            allocator.free(node.data);
            allocator.destroy(node);
            current = next;
        }
    }
};
