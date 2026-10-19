// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");
const io = source.net_io;
const queue_mod = source.net_looper.testing_helpers;
const WriteQueue = queue_mod.WriteQueue;

test "write queue preserves FIFO order and partial progress" {
    var queue = WriteQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.append(&.{ "abcd", "ef" }, null);
    try expectPending(&queue, "abcd", 0);

    try std.testing.expect(!queue.advance(2));
    try expectPending(&queue, "abcd", 2);

    try queue.append(&.{"gh"}, null);
    try std.testing.expect(queue.advance(2));
    try expectPending(&queue, "ef", 0);
    try std.testing.expect(queue.advance(2));
    try expectPending(&queue, "gh", 0);
    try std.testing.expect(queue.advance(2));
    try std.testing.expect(queue.pending() == null);
}

test "write queue owns packet copies" {
    var queue = WriteQueue.init(std.testing.allocator);
    defer queue.deinit();

    var packet = [_]u8{ 1, 2, 3 };
    try queue.append(&.{&packet}, null);
    packet[0] = 9;

    try expectPending(&queue, &.{ 1, 2, 3 }, 0);
}

test "write queue rolls back a failed batch" {
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var queue = WriteQueue.init(failing.allocator());
        defer queue.deinit();

        try std.testing.expectError(error.OutOfMemory, queue.append(&.{ "one", "two" }, null));
        try std.testing.expect(queue.pending() == null);
    }
}

test "write queue preserves existing partial state after append failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var queue = WriteQueue.init(failing.allocator());
    defer queue.deinit();

    try queue.append(&.{"head"}, null);
    try std.testing.expect(!queue.advance(2));
    try std.testing.expectError(error.OutOfMemory, queue.append(&.{ "one", "two" }, null));
    try expectPending(&queue, "head", 2);
    try std.testing.expect(queue.advance(2));
    try std.testing.expect(queue.pending() == null);
}

test "write queue accepts empty batches and packets" {
    var queue = WriteQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.append(&.{}, null);
    try std.testing.expect(queue.pending() == null);

    try queue.append(&.{""}, null);
    try expectPending(&queue, "", 0);
    try std.testing.expect(queue.advance(0));
    try std.testing.expect(queue.pending() == null);
}

fn expectPending(queue: *const WriteQueue, data: []const u8, offset: usize) !void {
    const pending = queue.pending() orelse return error.MissingPendingWrite;
    try std.testing.expectEqualSlices(u8, data, pending.data);
    try std.testing.expectEqual(offset, pending.offset);
}

test "write queue owns UDP payloads and destinations and rolls back failed batches" {
    var address = std.mem.zeroes(io.SocketAddress);
    address.family = 6;
    address.scope_id = 7;
    address.port = 12345;
    var payload = [_]u8{ 1, 2, 3 };
    var packets = [_]io.Datagram{.{ .payload = &payload, .address = address }};
    var queue = WriteQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.append(&.{packets[0].payload}, packets[0].address);
    payload[0] = 9;
    packets[0].address.port = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, queue.pending().?.data);
    try std.testing.expectEqual(@as(u16, 12345), queue.pending().?.address.?.port);
    try std.testing.expectEqual(@as(u32, 7), queue.pending().?.address.?.scope_id);
    for (0..4) |index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        var batch = WriteQueue.init(failing.allocator());
        defer batch.deinit();
        try std.testing.expectError(error.OutOfMemory, batch.append(&.{ packets[0].payload, packets[0].payload }, packets[0].address));
        try std.testing.expect(batch.pending() == null);
    }
}
