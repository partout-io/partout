// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const core = @import("../core/exports.zig");
const io = @import("io.zig");
const log = core.logging;

// FIXME: ###, anyerror

/// Fine-tuning.
pub const Options = struct {
    // FIXME: ###, *_buf_size unused by v2
    link_buf_size: usize = 64 * 1024,
    tun_buf_size: usize = 64 * 1024,
    max_read_size: usize = 256 * 1024,
    max_read_count: usize = 128,
    on_finish: OnFinish,
};

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
/// - .user comes from `OnRead` callback invocations
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

/// Infallible task submitted for delayed execution on the looper worker.
/// Error handling belongs to the owner because a task failure must not stop a
/// daemon-scoped looper shared by otherwise independent consumers.
pub const TimedTask = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque) void,

    pub fn call(self: TimedTask) void {
        self.callback(self.context);
    }
};

/// Identity of one replaceable delayed task. The looper never retains this
/// value's address; callers may store it inline with their queue-owned state.
pub const Timer = struct {
    id: ?u64 = null,
};

/// The arguments to attach a side of the looper.
pub const AttachArguments = struct {
    pair: io.DescriptorPair,
    /// Required by v2, including when on_read is null; ignored by v1.
    read_buffers: ?ReadBuffers = null,
    /// If absent, incoming data is read and discarded.
    on_read: ?OnRead = null,
    on_failure: ?OnFailure = null,
};

pub const SubmissionError = std.mem.Allocator.Error || error{LooperUnavailable};
pub const InitError = std.mem.Allocator.Error || error{MuxFailure};
pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError || error{
    AlreadyStarted,
};
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
pub const WriteOOBError = SubmissionError || io.Error || error{
    MissingDestination,
    OOBOutsideQueue,
    WriteIncomplete,
};

pub const CompletionError = std.mem.Allocator.Error || error{
    LooperUnavailable,
    MuxFailure,
    SideAlreadyAttached,
};

pub const Completion = struct {
    // Completion state.
    done: bool = false,
    // Completion failure or null on success.
    failure: ?CompletionError = null,
    // Intrusive completion queue linkage.
    next: ?*Completion = null,
};

/// Intrusive FIFO of synchronous command completions.
/// The queue is not thread-safe; callers must synchronize access.
pub const CompletionQueue = struct {
    pending: core.Fifo(Completion) = .{},

    pub fn append(
        self: *CompletionQueue,
        completion: *Completion,
        failure: ?CompletionError,
    ) void {
        completion.failure = failure;
        self.pending.append(completion);
    }

    pub fn releaseAll(self: *CompletionQueue) void {
        while (self.pending.take()) |completion| completion.done = true;
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
    perform: struct {
        task: Task,
        completion: *Completion,
    },
    timed_task: struct {
        id: u64,
        task: ?TimedTask,
    },
    stop,
};

/// A node in `CommandQueue`, with the payload and
/// an optional one-shot timer for deferred scheduling.
pub const CommandNode = struct {
    command: Command,
    timer: core.RunAfter.Scheduled = .{},

    // Synchronous callers keep their node on the stack until completion.
    // Asynchronous commands set this when allocating a persistent node.
    allocated: bool = false,

    // Intrusive command queue linkage.
    next: ?*CommandNode = null,

    // Intrusive linkage while a timed task is pending or ready.
    timer_next: ?*CommandNode = null,
};

/// A plain FIFO for the pending worker commands. Not thread-safe.
pub const CommandQueue = struct {
    pending: core.Fifo(CommandNode) = .{},

    pub fn append(self: *CommandQueue, node: *CommandNode) void {
        self.pending.append(node);
    }

    pub fn takeReady(self: *CommandQueue) ?*CommandNode {
        return self.pending.takeAll();
    }
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
/// FIXME: ###, Unused in v2
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

// I/O requests used by looper v2.

pub const IOError = io.Error || error{
    Cancelled,
    InvalidBuffers,
};

/// Number of whole packets processed, plus an optional failure. A partial
/// stream write is not counted; cancellation does not undo bytes already sent.
pub const IOResult = struct {
    count: usize = 0,
    failure: ?IOError = null,
};

/// Caller-owned storage. Only entries in the completed prefix have valid output.
pub const ReadBuffer = struct {
    data: []u8,
    size: usize = 0,
    source: ?io.SocketAddress = null,
};

/// Called exactly once for an accepted write request, on the looper without its lock.
/// Completion may run before submission returns. Rejected submissions never
/// invoke the callback. The entire buffer slice (descriptors and payloads)
/// must stay valid and exclusively loaned until completion; the callback context
/// must also remain valid. The destination is stored by value.
/// The callback may submit I/O, but must not call
/// attach, detach, stop, or deinit. Pending requests are cancelled before
/// detach, stop, or deinit returns; shutdown does not wait for I/O to drain.
pub const OnWriteComplete = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, IOResult) void,

    pub fn call(self: OnWriteComplete, result: IOResult) void {
        self.callback(self.context, result);
    }
};

/// Lends payload storage to spontaneous v2 reads. The looper owns neither the
/// descriptors nor their payloads. Both callbacks run on the looper without its
/// lock and must not call attach, detach, stop, or deinit. The provider context
/// must outlive the attachment.
pub const ReadBuffers = struct {
    context: ?*anyopaque = null,

    /// Lend writable buffers for one read attempt. Each buffer must have nonzero
    /// capacity. An empty slice pauses reading until resumeReading() is called.
    acquire: *const fn (?*anyopaque) []ReadBuffer,

    /// Return the entire loan after the read attempt and any on_read callback.
    /// Called once per acquisition, even when nothing was read or a read failed.
    /// Only result.count entries have valid size/source fields; the rest are unused.
    /// The owner may now reuse or recycle the storage. Release does not imply free.
    release: *const fn (?*anyopaque, []ReadBuffer, IOResult) void,
};

pub const WriteRequest = struct {
    packets: Packets,
    destination: ?io.SocketAddress,
    completion: OnWriteComplete,
    count: usize = 0,
    offset: usize = 0,
    next: ?*WriteRequest = null,

    pub fn pendingWrite(self: *const WriteRequest) PendingWrite {
        return .{
            .data = self.packets[self.count],
            .offset = self.offset,
            .address = self.destination,
        };
    }

    /// Advances this write, returning whether all packets have been written.
    pub fn advance(self: *WriteRequest, written: usize) bool {
        const remaining = self.packets[self.count].len - self.offset;
        std.debug.assert(written <= remaining);
        self.offset += written;
        if (written != remaining) return false;
        self.offset = 0;
        self.count += 1;
        return self.count == self.packets.len;
    }

    pub fn complete(
        self: *WriteRequest,
        allocator: std.mem.Allocator,
        failure: ?IOError,
    ) void {
        const completion = self.completion;
        const result = IOResult{ .count = self.count, .failure = failure };
        allocator.destroy(self);
        completion.call(result);
    }
};

/// Optional UDP batching for looper v2. A null read/write result selects
/// scalar I/O; platform support and socket eligibility stay inside this adapter.
pub const UDPBatch = struct {
    const supported = builtin.os.tag == .linux;
    backend: if (supported) ?LinuxUDPBatch else void = if (supported) null else {},

    pub fn init(descriptor: io.LinkDescriptor) UDPBatch {
        if (comptime !supported) return .{};
        if (!descriptor.io.isUnconnected()) return .{};
        const address = descriptor.localAddress() catch return .{};
        return .{ .backend = LinuxUDPBatch.init(descriptor.fd, address.family) };
    }

    pub fn write(self: *UDPBatch, packets: Packets, destination: ?io.SocketAddress) ?usize {
        if (comptime !supported) return null;
        const backend = if (self.backend) |*value| value else return null;
        return backend.write(packets, destination orelse return null);
    }

    pub fn read(self: *UDPBatch, buffers: []ReadBuffer, max_bytes: usize) ?usize {
        if (comptime !supported) return null;
        const backend = if (self.backend) |*value| value else return null;
        return backend.read(buffers, max_bytes);
    }
};

const LinuxUDPBatch = struct {
    const linux = std.os.linux;

    fd: i32,
    dual_stack: bool,
    can_read: bool = true,
    can_write: bool = true,
    const batch_size = 16;
    const max_datagram = 65535;
    const mapped_prefix = [_]u8{0} ** 10 ++ .{ 0xff, 0xff };

    pub fn init(fd: i32, family: u8) ?LinuxUDPBatch {
        var v6_only: c_int = 1;
        if (family == 6) {
            var len: u32 = @sizeOf(c_int);
            if (linux.errno(linux.getsockopt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, std.mem.asBytes(&v6_only), &len)) != .SUCCESS) return null;
        }
        return .{ .fd = fd, .dual_stack = family == 6 and v6_only == 0 };
    }

    pub fn write(self: *LinuxUDPBatch, packets: Packets, destination: io.SocketAddress) ?usize {
        if (!self.can_write or packets.len < 2) return null;
        var address: linux.sockaddr.in6 = undefined;
        const address_len = nativeAddress(&address, self.dual_stack, destination) orelse return null;
        var messages: [batch_size]linux.mmsghdr = undefined;
        var vectors: [batch_size]std.posix.iovec = undefined;
        const count = @min(packets.len, batch_size);
        for (packets[0..count], 0..) |packet, i| {
            vectors[i] = .{ .base = @constCast(packet.ptr), .len = packet.len };
            messages[i] = std.mem.zeroes(linux.mmsghdr);
            messages[i].hdr = .{ .name = @ptrCast(&address), .namelen = address_len, .iov = @ptrCast(&vectors[i]), .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
        }
        while (true) {
            const result = linux.sendmmsg(self.fd, &messages, @intCast(count), linux.MSG.DONTWAIT);
            switch (linux.errno(result)) {
                .SUCCESS => return result,
                .INTR => continue,
                .NOSYS, .OPNOTSUPP, .PERM => self.can_write = false,
                else => {},
            }
            return null; // Scalar I/O retains its error handling and tracing.
        }
    }

    pub fn read(self: *LinuxUDPBatch, buffers: []ReadBuffer, max_bytes: usize) ?usize {
        if (!self.can_read or buffers.len < 2) return null;
        // Full UDP storage guarantees no truncation within a batch. Smaller
        // loans use the scalar path, which discards oversized packets in place.
        for (buffers) |buffer| if (buffer.data.len < max_datagram) return null;
        var messages: [batch_size]linux.mmsghdr = undefined;
        var vectors: [batch_size]std.posix.iovec = undefined;
        var addresses: [batch_size]linux.sockaddr.in6 = undefined;
        var received: usize = 0;
        var bytes: usize = 0;
        while (received < buffers.len) {
            // Respect the byte budget even for maximum-size datagrams. Like
            // scalar reads, always permit one packet to make forward progress.
            const count = @min(buffers.len - received, batch_size, @max(1, (max_bytes -| bytes) / max_datagram));
            for (buffers[received..][0..count], 0..) |buffer, i| {
                vectors[i] = .{ .base = buffer.data.ptr, .len = max_datagram };
                messages[i] = std.mem.zeroes(linux.mmsghdr);
                messages[i].hdr = .{ .name = @ptrCast(&addresses[i]), .namelen = @sizeOf(linux.sockaddr.in6), .iov = @ptrCast(&vectors[i]), .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            }
            const result = linux.recvmmsg(self.fd, &messages, @intCast(count), linux.MSG.DONTWAIT, null);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |err| {
                    if (err == .NOSYS or err == .OPNOTSUPP or err == .PERM) self.can_read = false;
                    return if (received != 0) received else null;
                },
            }
            for (0..result) |i| {
                const buffer = &buffers[received + i];
                buffer.size = messages[i].len;
                buffer.source = portableAddress(&addresses[i]);
                bytes += buffer.size;
            }
            received += result;
            if (result < count or bytes >= max_bytes) break;
        }
        return received;
    }

    fn nativeAddress(out: *linux.sockaddr.in6, dual_stack: bool, address: io.SocketAddress) ?u32 {
        if (address.family == 4 and !dual_stack) {
            const v4: *linux.sockaddr.in = @ptrCast(out);
            v4.* = .{ .port = std.mem.nativeToBig(u16, address.port), .addr = @bitCast(address.address[0..4].*) };
            return @sizeOf(linux.sockaddr.in);
        }
        if (address.family != 4 and address.family != 6) return null;
        out.* = .{ .port = std.mem.nativeToBig(u16, address.port), .flowinfo = 0, .addr = address.address, .scope_id = address.scope_id };
        if (address.family == 4) out.addr = mapped_prefix ++ address.address[0..4].*;
        return @sizeOf(linux.sockaddr.in6);
    }

    fn portableAddress(address: *const linux.sockaddr.in6) io.SocketAddress {
        var result = std.mem.zeroes(io.SocketAddress);
        if (address.family == linux.AF.INET) {
            const v4: *const linux.sockaddr.in = @ptrCast(address);
            result.family = 4;
            result.port = std.mem.bigToNative(u16, v4.port);
            result.address[0..4].* = @bitCast(v4.addr);
        } else if (std.mem.eql(u8, address.addr[0..12], &mapped_prefix)) {
            result.family = 4;
            result.port = std.mem.bigToNative(u16, address.port);
            result.address[0..4].* = address.addr[12..16].*;
        } else {
            result.family = 6;
            result.port = std.mem.bigToNative(u16, address.port);
            result.address = address.addr;
            result.scope_id = address.scope_id;
        }
        return result;
    }
};
