// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");

const CounterError = error{
    Rejected,
};

const CounterMessage = union(enum) {
    add: usize,
    fail,
};

const CounterState = struct {
    value: usize = 0,
    actor_thread_id: ?std.Thread.Id = null,
};

fn performCounter(state: *CounterState, message: CounterMessage) CounterError!void {
    state.actor_thread_id = std.Thread.getCurrentId();
    switch (message) {
        .add => |value| state.value += value,
        .fail => return error.Rejected,
    }
}

const CounterActor = source.core.Actor(
    CounterState,
    CounterMessage,
    CounterError,
    performCounter,
);

test "actor serializes sync and async messages" {
    const allocator = std.testing.allocator;
    const main_thread_id = std.Thread.getCurrentId();

    var state = CounterState{};
    const actor = try CounterActor.create(allocator, &state);
    defer actor.deinit();

    try actor.post(.{ .add = 2 });
    try actor.call(.{ .add = 4 });

    try std.testing.expectEqual(@as(usize, 6), state.value);
    try std.testing.expect(state.actor_thread_id != null);
    try std.testing.expect(state.actor_thread_id.? != main_thread_id);
}

test "actor propagates errors and rejects messages after shutdown" {
    const allocator = std.testing.allocator;

    var state = CounterState{};
    const actor = try CounterActor.create(allocator, &state);
    defer actor.deinit();

    try std.testing.expectError(error.Rejected, actor.call(.fail));

    actor.shutdown();
    try std.testing.expectError(error.Closed, actor.call(.{ .add = 1 }));
    try std.testing.expectError(error.Closed, actor.call(.{ .add = 1 }));
}
