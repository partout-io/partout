// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Intrusive FIFO for nodes with a `next: ?*Node` field. Does not allocate,
/// free, or synchronize. Nodes must remain at stable addresses while queued
/// and may belong to only one queue at a time. The owner supplies locking.
pub fn Fifo(comptime Node: type) type {
    return struct {
        const Self = @This();

        head: ?*Node = null,
        tail: ?*Node = null,

        pub fn append(self: *Self, node: *Node) void {
            node.next = null;
            if (self.tail) |tail| tail.next = node else self.head = node;
            self.tail = node;
        }

        pub fn take(self: *Self) ?*Node {
            const node = self.head orelse return null;
            self.head = node.next;
            if (self.head == null) self.tail = null;
            node.next = null;
            return node;
        }

        /// Detaches the entire chain, preserving its links for traversal.
        pub fn takeAll(self: *Self) ?*Node {
            const head = self.head;
            self.* = .{};
            return head;
        }

        /// Moves another queue's nodes to the tail without allocating.
        /// The queues must be distinct.
        pub fn appendQueue(self: *Self, other: *Self) void {
            const head = other.head orelse return;
            if (self.tail) |tail| tail.next = head else self.head = head;
            self.tail = other.tail;
            other.* = .{};
        }
    };
}
