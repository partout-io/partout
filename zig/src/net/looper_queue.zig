// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const io = @import("io.zig");

pub const ReadAction = enum {
    keep,
    pause,
};

pub const Packet = []const u8;
pub const Packets = []const Packet;

pub const TransformWrite = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Packets) anyerror!Packets,

    pub fn call(self: TransformWrite, packets: Packets) anyerror!Packets {
        return self.callback(self.context, packets);
    }
};

pub const OnRead = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Packets) anyerror!ReadAction,

    pub fn call(self: OnRead, packets: Packets) anyerror!ReadAction {
        return self.callback(self.context, packets);
    }
};

pub const Failure = union(enum) {
    mux: ?io.Side,
    wait: c_int,
    io: struct {
        side: io.Side,
        cause: io.Error,
        code: ?c_int,
    },
    user: anyerror,
    system: io.Error,
};

pub const OnFailure = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Failure) void,

    pub fn call(self: OnFailure, failure: Failure) void {
        self.callback(self.context, failure);
    }
};

pub const Task = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque) anyerror!void,

    pub fn call(self: Task) anyerror!void {
        return self.callback(self.context);
    }
};

pub const Descriptor = struct {
    fd: io.FileDescriptor,
    io: io.IOInterface,
};

pub const DescriptorPair = union(io.Side) {
    link: Descriptor,
    tun: Descriptor,
};

pub const AttachArguments = struct {
    pair: DescriptorPair,

    transform_write: ?TransformWrite = null,
    on_read: ?OnRead = null,
    on_failure: ?OnFailure = null,
};

pub const CompletionError = error{
    Cancelled,
    MuxFailure,
    OperationCancelled,
    OutOfMemory,
    TerminalFailure,
};

pub const Completion = struct {
    // Completion state.
    done: bool = false,
    result: ?CompletionError = null,

    // Intrusive completion queue linkage.
    next: ?*Completion = null,
};

/// Intrusive FIFO of synchronous command completions.
/// The queue is not thread-safe; callers must synchronize access.
pub const CompletionQueue = struct {
    head: ?*Completion = null,
    tail: ?*Completion = null,

    pub fn append(
        self: *CompletionQueue,
        completion: *Completion,
        result: ?CompletionError,
    ) void {
        completion.result = result;
        completion.next = null;
        if (self.tail) |tail| {
            tail.next = completion;
        } else {
            self.head = completion;
        }
        self.tail = completion;
    }

    pub fn releaseAll(self: *CompletionQueue) void {
        var current = self.head;
        while (current) |completion| {
            const next = completion.next;
            completion.next = null;
            completion.done = true;
            current = next;
        }
        self.head = null;
        self.tail = null;
    }
};

pub const SideIdentity = struct {
    side: io.Side,
    id: ?u64,
};

pub const Command = union(enum) {
    attach: struct {
        arguments: AttachArguments,
        completion: *Completion,
    },
    detach: struct {
        side: io.Side,
        completion: *Completion,
    },
    enable_read: SideIdentity,
    enable_write: SideIdentity,
    perform: struct {
        task: Task,
        completion: *Completion,
    },
    custom: Task,
    stop,
};

pub const CommandNode = struct {
    // Command payload and scheduling metadata.
    command: Command,
    deadline_ns: u64 = 0,

    // Intrusive command queue linkage.
    next: ?*CommandNode = null,
};

pub const CommandQueue = struct {
    // Ready FIFO.
    ready_head: ?*CommandNode = null,
    ready_tail: ?*CommandNode = null,

    // Deadline-ordered scheduled list.
    scheduled_head: ?*CommandNode = null,

    pub fn append(self: *CommandQueue, node: *CommandNode) void {
        node.next = null;
        if (self.ready_tail) |tail| {
            tail.next = node;
        } else {
            self.ready_head = node;
        }
        self.ready_tail = node;
    }

    pub fn takeReady(self: *CommandQueue) ?*CommandNode {
        const pending = self.ready_head;
        self.ready_head = null;
        self.ready_tail = null;
        return pending;
    }

    /// Inserts by absolute deadline, preserving FIFO order for equal deadlines.
    /// Returns whether `node` became the earliest scheduled command.
    pub fn insertScheduled(self: *CommandQueue, node: *CommandNode) bool {
        node.next = null;
        const head = self.scheduled_head orelse {
            self.scheduled_head = node;
            return true;
        };
        if (node.deadline_ns < head.deadline_ns) {
            node.next = head;
            self.scheduled_head = node;
            return true;
        }

        var previous = head;
        while (previous.next) |next| {
            if (node.deadline_ns < next.deadline_ns) break;
            previous = next;
        }
        node.next = previous.next;
        previous.next = node;
        return false;
    }

    pub fn popDue(self: *CommandQueue, now_ns: u64) ?*CommandNode {
        const node = self.scheduled_head orelse return null;
        if (node.deadline_ns > now_ns) return null;
        self.scheduled_head = node.next;
        node.next = null;
        return node;
    }

    pub fn takeScheduled(self: *CommandQueue) ?*CommandNode {
        const scheduled = self.scheduled_head;
        self.scheduled_head = null;
        return scheduled;
    }

    pub fn waitTimeoutMs(self: *const CommandQueue, now_ns: u64) c_int {
        if (self.ready_head != null) return 0;
        const deadline_ns = if (self.scheduled_head) |node|
            node.deadline_ns
        else
            return -1;
        if (deadline_ns <= now_ns) return 0;

        const remaining_ns = deadline_ns - now_ns;
        var timeout_ms = remaining_ns / std.time.ns_per_ms;
        if (remaining_ns % std.time.ns_per_ms != 0) timeout_ms += 1;
        const max_timeout_ms: u64 = @intCast(std.math.maxInt(c_int));
        return @intCast(@min(timeout_ms, max_timeout_ms));
    }
};

pub const PendingWrite = struct {
    data: []const u8,
    offset: usize,
};

const WriteNode = struct {
    data: []u8,
    next: ?*WriteNode = null,
};

/// Owned FIFO of packet buffers with partial consumption of the head packet.
/// The queue is not thread-safe; callers must synchronize access.
pub const WriteQueue = struct {
    allocator: std.mem.Allocator,

    // Owned FIFO and partial head progress.
    head: ?*WriteNode = null,
    tail: ?*WriteNode = null,
    offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator) WriteQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WriteQueue) void {
        destroyList(self.allocator, self.head);
        self.head = null;
        self.tail = null;
        self.offset = 0;
    }

    /// Copies and appends the entire packet batch, or leaves the queue unchanged.
    pub fn append(self: *WriteQueue, packets: Packets) std.mem.Allocator.Error!void {
        var new_head: ?*WriteNode = null;
        var new_tail: ?*WriteNode = null;
        errdefer destroyList(self.allocator, new_head);

        for (packets) |packet| {
            const copy = try self.allocator.dupe(u8, packet);
            errdefer self.allocator.free(copy);
            const node = try self.allocator.create(WriteNode);
            node.* = .{ .data = copy };
            if (new_tail) |tail| {
                tail.next = node;
            } else {
                new_head = node;
            }
            new_tail = node;
        }

        if (new_head) |head| {
            if (self.tail) |tail| {
                tail.next = head;
            } else {
                self.head = head;
            }
            self.tail = new_tail;
        }
    }

    /// Returns a borrowed view of the head packet and its current offset.
    pub fn pending(self: *const WriteQueue) ?PendingWrite {
        const first = self.head orelse return null;
        return .{
            .data = first.data,
            .offset = self.offset,
        };
    }

    /// Advances the head packet and returns whether it was fully consumed.
    pub fn advance(self: *WriteQueue, written: usize) bool {
        const first = self.head orelse unreachable;
        const remaining = first.data.len - self.offset;
        std.debug.assert(written <= remaining);
        if (written < remaining) {
            self.offset += written;
            return false;
        }

        self.head = first.next;
        if (self.head == null) self.tail = null;
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
