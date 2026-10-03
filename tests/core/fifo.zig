// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const Fifo = @import("source").core.Fifo;
const Node = struct { next: ?*Node = null };

test "FIFO preserves order, unlinks popped nodes, and supports reuse" {
    var queue = Fifo(Node){};
    var first = Node{};
    var second = Node{};
    try std.testing.expect(queue.take() == null);
    queue.append(&first);
    queue.append(&second);
    try std.testing.expect(queue.take() == &first);
    try std.testing.expect(first.next == null);
    queue.append(&first);
    try std.testing.expect(queue.take() == &second);
    try std.testing.expect(queue.take() == &first);
    try std.testing.expect(queue.head == null and queue.tail == null);
}

test "FIFO detaches chains and moves queues without sharing ownership" {
    var queue = Fifo(Node){};
    var pending = Fifo(Node){};
    var first = Node{};
    var second = Node{};
    var third = Node{};
    queue.appendQueue(&pending);
    pending.append(&first);
    queue.appendQueue(&pending);
    try std.testing.expect(pending.head == null and pending.tail == null);
    pending.append(&second);
    pending.append(&third);
    queue.appendQueue(&pending);
    try std.testing.expect(pending.head == null and pending.tail == null);
    const chain = queue.takeAll().?;
    try std.testing.expect(chain == &first);
    try std.testing.expect(chain.next == &second);
    try std.testing.expect(chain.next.?.next == &third);
    try std.testing.expect(third.next == null);
    try std.testing.expect(queue.head == null and queue.tail == null);
    queue.append(&first);
    try std.testing.expect(queue.take() == &first);
    try std.testing.expect(queue.takeAll() == null);
}
