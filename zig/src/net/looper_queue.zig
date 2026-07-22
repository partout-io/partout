// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const concurrency = @import("../core/concurrency.zig");
const io = @import("io.zig");

/// Single binary data packet.
pub const Packet = []const u8;
/// Slice of packets.
pub const Packets = []const Packet;

/// The `OnRead` callback returns an action. Consumers will
/// normally `.keep` reading (default behavior), but may also
/// return `.pause` to temporarily suspend the observation
/// of read events.
pub const ReadAction = enum {
    keep,
    pause,
};

/// Transformation callback to apply before submitting packets
/// to the write queue.
pub const TransformWrite = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Packets) anyerror!Packets,

    pub fn call(self: TransformWrite, packets: Packets) anyerror!Packets {
        return self.callback(self.context, packets);
    }
};

/// Invoked on read events from either looper side.
pub const OnRead = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Packets) anyerror!ReadAction,

    pub fn call(self: OnRead, packets: Packets) anyerror!ReadAction {
        return self.callback(self.context, packets);
    }
};

/// Returns details about the underlying reason of a deferred
/// failure. It represents the former Swift errors:
///
/// - SideError(Side, Error?) -> .user
/// - WaitError(errno) -> .wait
/// - NativeIOError -> .io
///
/// Precisely:
///
/// - .wait and .system are fatal syscall failures
/// - .io causes a side to be detached, but lets the loop continue
/// - .user comes from `OnRead` and `Task` callback invocations
///
/// Swift MuxError is resolved to error.MuxFailure and is not
/// mapped here because it's always returned synchronously.
pub const Failure = union(enum) {
    wait: c_int,
    system: io.Error,
    io: struct {
        side: io.Side,
        cause: io.Error,
        code: ?c_int,
    },
    user: anyerror,
};

/// Invoked on any failure event.
pub const OnFailure = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Failure) void,

    pub fn call(self: OnFailure, failure: Failure) void {
        self.callback(self.context, failure);
    }
};

/// Invoked when the looper finishes, with the optional failure.
pub const OnFinish = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, ?Failure) void,

    pub fn call(self: OnFinish, failure: ?Failure) void {
        self.callback(self.context, failure);
    }
};

/// Runs a generic task in the worker thread.
pub const Task = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque) anyerror!void,

    pub fn call(self: Task) anyerror!void {
        return self.callback(self.context);
    }
};

/// A descriptor includes:
/// - The `fd` to watch for I/O events.
/// - The `io` interface to perform reads and writes.
pub const Descriptor = struct {
    fd: io.FileDescriptor,
    io: io.IOInterface,
};

/// The looper manages exactly one link and one tun (at most).
pub const DescriptorPair = union(io.Side) {
    link: Descriptor,
    tun: Descriptor,
};

/// The arguments to attach a side of the looper.
pub const AttachArguments = struct {
    pair: DescriptorPair,
    transform_write: ?TransformWrite = null,
    on_read: ?OnRead = null,
    on_failure: ?OnFailure = null,
};

/// Exact error sets used to compose the looper API. Keeping every custom
/// error name here makes misspellings in set compositions a compile error.
pub const Errors = struct {
    pub const AlreadyStarted = error{AlreadyStarted};
    pub const Cancelled = error{Cancelled};
    pub const InvalidState = error{InvalidState};
    pub const MuxFailure = error{MuxFailure};
    pub const OperationCancelled = error{OperationCancelled};
    pub const ReentrantCall = error{ReentrantCall};
    pub const TaskFailure = error{TaskFailure};
    pub const TerminalFailure = error{TerminalFailure};
    pub const TransformFailure = error{TransformFailure};
    pub const WriteIncomplete = error{WriteIncomplete};
};

pub const CompletionError = std.mem.Allocator.Error ||
    Errors.Cancelled ||
    Errors.MuxFailure ||
    Errors.OperationCancelled ||
    Errors.TerminalFailure;

pub const Completion = struct {
    // Completion state.
    done: bool = false,
    // Completion error or null on success.
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

/// Uniquely identifies a side. Acts as a discriminator
/// if a task is submitted to a side but the side is
/// detached before the task is actually executed.
pub const SideIdentity = struct {
    side: io.Side,
    id: ?u64,
};

/// These are the supported commands by the looper worker.
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
    schedule: struct {
        task: Task,
        completion: *Completion,
    },
    perform: Task,
    stop,
};

/// A node in `CommandQueue`, with the payload and
/// an optional one-shot timer for deferred scheduling.
pub const CommandNode = struct {
    command: Command,
    timer: concurrency.RunAfter.Scheduled = .{},

    // Intrusive command queue linkage.
    next: ?*CommandNode = null,
};

/// A plain FIFO for the pending worker commands. Not thread-safe.
pub const CommandQueue = struct {
    ready_head: ?*CommandNode = null,
    ready_tail: ?*CommandNode = null,

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
};

/// Helps storing a pending write without copying the
/// original buffer to a partial buffer.
pub const PendingWrite = struct {
    data: []const u8,
    offset: usize,
};

/// A node in `WriteQueue`.
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
