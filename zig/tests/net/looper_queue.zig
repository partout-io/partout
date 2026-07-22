// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const queue_mod = @import("source").net_looper_queue;
const Completion = queue_mod.Completion;
const CompletionQueue = queue_mod.CompletionQueue;
const CommandNode = queue_mod.CommandNode;
const CommandQueue = queue_mod.CommandQueue;
const WriteQueue = queue_mod.WriteQueue;

test "completion queue releases completions in FIFO order" {
    var queue = CompletionQueue{};
    var first = Completion{};
    var second = Completion{};

    queue.append(&first, null);
    queue.append(&second, error.Cancelled);

    try std.testing.expect(first.next == &second);
    try std.testing.expect(second.next == null);
    try std.testing.expect(!first.done);
    try std.testing.expect(!second.done);
    try std.testing.expect(second.result.? == error.Cancelled);

    queue.releaseAll();

    try std.testing.expect(first.done);
    try std.testing.expect(second.done);
    try std.testing.expect(first.next == null);
    try std.testing.expect(second.next == null);

    var third = Completion{};
    queue.append(&third, error.TerminalFailure);
    queue.releaseAll();
    try std.testing.expect(third.done);
    try std.testing.expect(third.result.? == error.TerminalFailure);
}

test "command queue detaches ready commands in FIFO order" {
    var queue = CommandQueue{};
    var first = CommandNode{ .command = .stop };
    var second = CommandNode{ .command = .stop };

    queue.append(&first);
    queue.append(&second);

    const pending = queue.takeReady().?;
    try std.testing.expect(pending == &first);
    try std.testing.expect(pending.next == &second);
    try std.testing.expect(second.next == null);
    try std.testing.expect(queue.takeReady() == null);
}

test "write queue preserves FIFO order and partial progress" {
    var queue = WriteQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.append(&.{ "abcd", "ef" });
    try expectPending(&queue, "abcd", 0);

    try std.testing.expect(!queue.advance(2));
    try expectPending(&queue, "abcd", 2);

    try queue.append(&.{"gh"});
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
    try queue.append(&.{&packet});
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

        try std.testing.expectError(error.OutOfMemory, queue.append(&.{ "one", "two" }));
        try std.testing.expect(queue.pending() == null);
    }
}

test "write queue preserves existing partial state after append failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var queue = WriteQueue.init(failing.allocator());
    defer queue.deinit();

    try queue.append(&.{"head"});
    try std.testing.expect(!queue.advance(2));
    try std.testing.expectError(error.OutOfMemory, queue.append(&.{ "one", "two" }));
    try expectPending(&queue, "head", 2);
    try std.testing.expect(queue.advance(2));
    try std.testing.expect(queue.pending() == null);
}

test "write queue accepts empty batches and packets" {
    var queue = WriteQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.append(&.{});
    try std.testing.expect(queue.pending() == null);

    try queue.append(&.{""});
    try expectPending(&queue, "", 0);
    try std.testing.expect(queue.advance(0));
    try std.testing.expect(queue.pending() == null);
}

fn expectPending(queue: *const WriteQueue, data: []const u8, offset: usize) !void {
    const pending = queue.pending() orelse return error.MissingPendingWrite;
    try std.testing.expectEqualSlices(u8, data, pending.data);
    try std.testing.expectEqual(offset, pending.offset);
}
