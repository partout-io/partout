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

fn performCounter(state: *CounterState, comptime Result: type, message: CounterMessage) CounterError!Result {
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
    defer actor.destroy();

    try actor.schedule(.{ .add = 2 });
    try actor.perform(void, .{ .add = 4 });

    try std.testing.expectEqual(@as(usize, 6), state.value);
    try std.testing.expect(state.actor_thread_id != null);
    try std.testing.expect(state.actor_thread_id.? != main_thread_id);
}

test "actor propagates errors and rejects messages after shutdown" {
    const allocator = std.testing.allocator;

    var state = CounterState{};
    const actor = try CounterActor.create(allocator, &state);
    defer actor.destroy();

    try std.testing.expectError(error.Rejected, actor.perform(void, .fail));

    actor.shutdown();
    try std.testing.expectError(error.Closed, actor.perform(void, .{ .add = 1 }));
    try std.testing.expectError(error.Closed, actor.schedule(.{ .add = 1 }));
}

const ResultState = struct {
    const Actor = source.core.Actor(ResultState, Message, CounterError, handle);
    const Message = union(enum) {
        add: usize,
        nested,
        nested_fail,
        fail,
    };

    actor: ?*Actor = null,
    value: usize = 0,

    fn handle(self: *ResultState, comptime Result: type, message: Message) CounterError!Result {
        switch (message) {
            .add => |value| self.value += value,
            .nested => return self.actor.?.perform(Result, .{ .add = 3 }) catch |err| switch (err) {
                error.Closed => unreachable,
                else => |domain_error| return domain_error,
            },
            .nested_fail => return self.actor.?.perform(Result, .fail) catch |err| switch (err) {
                error.Closed => unreachable,
                else => |domain_error| return domain_error,
            },
            .fail => return error.Rejected,
        }
        return if (Result == void) {} else if (Result == bool) self.value > 0 else self.value;
    }
};

test "actor returns typed results for queued and nested messages" {
    var state = ResultState{};
    const actor = try ResultState.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    state.actor = actor;

    try actor.schedule(.{ .add = 2 });
    try std.testing.expectEqual(@as(usize, 6), try actor.perform(usize, .{ .add = 4 }));
    try std.testing.expectEqual(@as(usize, 9), try actor.perform(usize, .nested));
    try std.testing.expect(try actor.perform(bool, .{ .add = 0 }));
    try actor.perform(void, .{ .add = 0 });
    try std.testing.expectError(error.Rejected, actor.perform(usize, .fail));
    try std.testing.expectError(error.Rejected, actor.perform(usize, .nested_fail));
    try actor.schedule(.fail);
    try std.testing.expectEqual(@as(usize, 10), try actor.perform(usize, .{ .add = 1 }));

    actor.shutdown();
    try std.testing.expectError(error.Closed, actor.perform(usize, .{ .add = 1 }));
    try std.testing.expectError(error.Closed, actor.schedule(.{ .add = 1 }));
}

const PayloadState = struct {
    const Actor = source.core.Actor(PayloadState, Message, CounterError, handle);
    const Payload = struct {
        words: [64]u64 align(64),
        owner: *const usize,
        optional: ?usize,
    };
    const Message = union(enum) {
        echo: Payload,
        nested: Payload,
        fail,
    };

    actor: ?*Actor = null,

    fn handle(self: *PayloadState, comptime Result: type, message: Message) CounterError!Result {
        std.debug.assert(self.actor.?.isOnQueue());
        switch (message) {
            .echo => |payload| return if (Result == void) {} else payload,
            .nested => |payload| return self.actor.?.perform(Result, .{ .echo = payload }) catch |err| switch (err) {
                error.Closed => unreachable,
                else => |domain_error| return domain_error,
            },
            .fail => return error.Rejected,
        }
    }
};

test "actor preserves aligned aggregate results and recovers after errors" {
    var state = PayloadState{};
    const actor = try PayloadState.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    state.actor = actor;
    try std.testing.expect(!actor.isOnQueue());

    const owner: usize = 42;
    for ([_]?usize{ null, 17 }) |optional| {
        const payload = PayloadState.Payload{
            .words = [_]u64{0x0123456789abcdef} ** 64,
            .owner = &owner,
            .optional = optional,
        };
        try std.testing.expectError(error.Rejected, actor.perform(PayloadState.Payload, .fail));
        const queued = try actor.perform(PayloadState.Payload, .{ .echo = payload });
        const nested = try actor.perform(PayloadState.Payload, .{ .nested = payload });
        try std.testing.expectEqualDeep(payload, queued);
        try std.testing.expectEqualDeep(payload, nested);
        try std.testing.expect(queued.owner == &owner);
        try std.testing.expect(nested.owner == &owner);
    }
    actor.shutdown();
    try std.testing.expect(!actor.isOnQueue());
    try std.testing.expectError(error.Closed, actor.perform(PayloadState.Payload, .fail));
}

test "actor keeps concurrent callers results and errors isolated" {
    const Caller = struct {
        actor: *PayloadState.Actor,
        id: usize,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }

        fn check(self: *@This()) !void {
            for (0..128) |iteration| {
                const payload = PayloadState.Payload{
                    .words = [_]u64{@intCast(self.id * 128 + iteration)} ** 64,
                    .owner = &self.id,
                    .optional = if (iteration % 2 == 0) iteration else null,
                };
                try std.testing.expectError(error.Rejected, self.actor.perform(PayloadState.Payload, .fail));
                const result = try self.actor.perform(PayloadState.Payload, .{ .echo = payload });
                try std.testing.expectEqualDeep(payload, result);
                try std.testing.expect(result.owner == &self.id);
            }
        }
    };

    var state = PayloadState{};
    const actor = try PayloadState.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    state.actor = actor;
    var callers: [8]Caller = undefined;
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    // Join even if spawning a later caller fails, before destroying the actor.
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&callers, 0..) |*caller, id| {
            caller.* = .{ .actor = actor, .id = id };
            threads[id] = try std.Thread.spawn(.{}, Caller.run, .{caller});
            started += 1;
        }
    }
    for (callers) |caller| if (caller.failure) |err| return err;
}

test "actor shutdown drains scheduled work and permits typed finish callbacks" {
    const State = struct {
        const Actor = source.core.actor.ActorWithFinish(@This(), Message, CounterError, handle, finish);
        const Message = union(enum) { add: usize, read, fail };
        actor: ?*Actor = null,
        value: usize = 0,
        finish_count: usize = 0,
        final_value: ?usize = null,
        finish_on_queue: bool = false,
        finish_error: ?anyerror = null,

        fn handle(self: *@This(), comptime Result: type, message: Message) CounterError!Result {
            switch (message) {
                .add => |value| self.value += value,
                .read => {},
                .fail => return error.Rejected,
            }
            return if (Result == void) {} else self.value;
        }

        fn finish(self: *@This()) void {
            self.finish_count += 1;
            self.finish_on_queue = self.actor.?.isOnQueue();
            self.final_value = self.actor.?.perform(usize, .read) catch |err| {
                self.finish_error = err;
                return;
            };
        }
    };

    var state = State{};
    const actor = try State.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    state.actor = actor;
    for (1..101) |value| try actor.schedule(.{ .add = value });
    try actor.schedule(.fail);
    try actor.schedule(.{ .add = 1 });
    actor.shutdown();
    try std.testing.expectEqual(@as(?anyerror, null), state.finish_error);
    try std.testing.expectEqual(@as(?usize, 5051), state.final_value);
    try std.testing.expect(state.finish_on_queue);
    try std.testing.expect(!actor.isOnQueue());
    try std.testing.expectError(error.Closed, actor.perform(usize, .read));
    actor.shutdown();
    try std.testing.expectEqual(@as(usize, 1), state.finish_count);
}
