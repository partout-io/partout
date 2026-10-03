// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Borrowed buffers and I/O requests used only by looper v2.
const std = @import("std");
const helpers = @import("looper_helpers.zig");
const io = @import("io.zig");

/// Caller-owned storage. Only entries in the completed prefix have valid output.
pub const ReadBuffer = struct {
    data: []u8,
    size: usize = 0,
    source: ?io.SocketAddress = null,
};

/// Number of whole packets processed, plus an optional failure. A partial
/// stream write is not counted; cancellation does not undo bytes already sent.
pub const Result = struct {
    count: usize = 0,
    failure: ?(io.Error || error{Cancelled}) = null,
};

/// Called exactly once for an accepted request, on the looper without its lock.
/// Completion may run before submission returns. Rejected submissions never
/// invoke the callback. The entire buffer slice (descriptors and payloads)
/// must stay valid and exclusively loaned until completion; the callback context
/// must also remain valid. The destination is stored by value.
/// The callback may submit I/O, but must not call
/// attach, detach, stop, or deinit. Pending requests are cancelled before
/// detach, stop, or deinit returns; shutdown does not wait for I/O to drain.
pub const Completion = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Result) void,

    pub fn call(self: Completion, result: Result) void {
        self.callback(self.context, result);
    }
};

pub const SubmissionError = helpers.SubmissionError || error{
    SideNotAttached,
    InvalidBuffers,
};
pub const WriteError = SubmissionError || error{MissingDestination};

pub const AttachArguments = struct {
    pair: io.DescriptorPair,
    on_failure: ?helpers.OnFailure = null,
};

pub const ReadRequest = struct {
    buffers: []ReadBuffer,
    completion: Completion,
    next: ?*ReadRequest = null,

    pub fn complete(self: *ReadRequest, allocator: std.mem.Allocator, result: Result) void {
        const completion = self.completion;
        allocator.destroy(self);
        completion.call(result);
    }
};

pub const WriteRequest = struct {
    packets: helpers.Packets,
    destination: ?io.SocketAddress,
    completion: Completion,
    count: usize = 0,
    offset: usize = 0,
    next: ?*WriteRequest = null,

    pub fn pending(self: *const WriteRequest) helpers.PendingWrite {
        return .{ .data = self.packets[self.count], .offset = self.offset, .address = self.destination };
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

    pub fn complete(self: *WriteRequest, allocator: std.mem.Allocator, failure: ?(io.Error || error{Cancelled})) void {
        const completion = self.completion;
        const result = Result{ .count = self.count, .failure = failure };
        allocator.destroy(self);
        completion.call(result);
    }
};
