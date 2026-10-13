// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");
const mux_c = source.ffi.io;

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
    null,
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
    const Actor = source.core.Actor(ResultState, null, Message, CounterError, handle);
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
    const Actor = source.core.Actor(PayloadState, null, Message, CounterError, handle);
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

test "actor driver finishes on its worker after draining scheduled work" {
    const State = struct {
        const Self = @This();
        const Actor = source.core.actor.Actor(Self, Driver, Message, CounterError, handle);
        const Message = union(enum) { add: usize, read, fail };
        actor: ?*Actor = null,
        value: usize = 0,
        finish_count: usize = 0,
        final_value: ?usize = null,
        finish_on_queue: bool = false,
        finish_error: ?anyerror = null,

        const Driver = source.core.actor.DefaultDriver(Self, finish);

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

const AtomicBool = std.atomic.Value(bool);
const AtomicCount = std.atomic.Value(usize);

fn waitForFlag(flag: *const AtomicBool) !void {
    const deadline = source.core.monotonicNs() + 5 * std.time.ns_per_s;
    while (!flag.load(.acquire)) {
        if (source.core.monotonicNs() >= deadline) return error.Timeout;
        source.core.sleepMs(1);
    }
}

// Watch an external wake descriptor, as the caller-driven looper does. Polling
// this mux leaves the actor's wake latched until resetWake() clears it.
const DrivenState = struct {
    const Actor = source.core.actor.Actor(@This(), Driver, Message, CounterError, handle);
    const Message = union(enum) { add: usize, echo: usize, read, nested, fail, block };

    wake_mux: mux_c.pp_mux,
    poll_mux: mux_c.pp_mux,
    io_mux: mux_c.pp_mux,
    actor: ?*Actor = null,
    value: usize = 0,
    loop_thread: ?std.Thread.Id = null,
    handler_thread: ?std.Thread.Id = null,
    io_value: ?usize = null,
    nested_io_result: ?usize = null,
    finish_count: usize = 0,
    final_value: ?usize = null,
    finish_on_queue: bool = false,
    failed: AtomicBool = .init(false),
    wakes: AtomicCount = .init(0),
    polls: AtomicCount = .init(0),
    waits: AtomicCount = .init(0),
    io_events: AtomicCount = .init(0),
    hold_next_wait: AtomicBool = .init(false),
    wait_armed: AtomicBool = .init(false),
    release_wait: AtomicBool = .init(false),
    job_entered: AtomicBool = .init(false),
    release_job: AtomicBool = .init(false),

    fn init() !DrivenState {
        const wake_mux = mux_c.pp_mux_create(1) orelse return error.MuxCreationFailed;
        errdefer mux_c.pp_mux_free(wake_mux);
        const poll_mux = mux_c.pp_mux_create(2) orelse return error.MuxCreationFailed;
        errdefer mux_c.pp_mux_free(poll_mux);
        const io_mux = mux_c.pp_mux_create(1) orelse return error.MuxCreationFailed;
        errdefer mux_c.pp_mux_free(io_mux);
        try std.testing.expect(mux_c.pp_mux_add(poll_mux, mux_c.pp_mux_wake_descriptor(wake_mux)));
        try std.testing.expect(mux_c.pp_mux_add(poll_mux, mux_c.pp_mux_wake_descriptor(io_mux)));
        return .{ .wake_mux = wake_mux, .poll_mux = poll_mux, .io_mux = io_mux };
    }

    fn deinit(self: *DrivenState) void {
        mux_c.pp_mux_free(self.poll_mux);
        mux_c.pp_mux_free(self.io_mux);
        mux_c.pp_mux_free(self.wake_mux);
    }

    const Driver = struct {
        state: *DrivenState,
        completion: source.core.actor.DefaultDriver(DrivenState, null),

        pub fn init(mutex: *source.core.Mutex, state: *DrivenState) Driver {
            mux_c.pp_mux_set_on_readable(state.poll_mux, onReadable, state);
            return .{ .state = state, .completion = .init(mutex, state) };
        }

        pub fn finish(_: *Driver, context: *DrivenState) void {
            context.finish();
        }

        pub fn deinit(self: *Driver) void {
            self.completion.deinit();
        }

        pub fn wait(self: *Driver) void {
            self.completion.wait();
        }

        pub fn notify(self: *Driver) void {
            self.completion.notify();
        }

        pub fn wake(self: *Driver) void {
            self.state.wake();
        }

        pub fn resetWake(self: *Driver) void {
            self.state.resetWake();
        }

        pub fn loopOnce(self: *Driver, context: *DrivenState, max_wait_ms: ?u32) void {
            std.debug.assert(context == self.state);
            self.state.loopOnce(max_wait_ms);
        }
    };

    fn unblock(self: *DrivenState) void {
        self.release_wait.store(true, .release);
        self.release_job.store(true, .release);
    }

    fn wake(self: *DrivenState) void {
        if (!mux_c.pp_mux_wake(self.wake_mux)) self.failed.store(true, .release);
        _ = self.wakes.fetchAdd(1, .release);
    }

    fn resetWake(self: *DrivenState) void {
        if (!mux_c.pp_mux_reset_wake(self.wake_mux)) self.failed.store(true, .release);
    }

    fn loopOnce(self: *DrivenState, max_wait_ms: ?u32) void {
        const current = std.Thread.getCurrentId();
        if (self.loop_thread) |previous| {
            if (previous != current) self.failed.store(true, .release);
        } else self.loop_thread = current;
        if (max_wait_ms == null) {
            _ = self.waits.fetchAdd(1, .release);
            if (self.hold_next_wait.swap(false, .acq_rel)) {
                self.wait_armed.store(true, .release);
                waitForFlag(&self.release_wait) catch self.failed.store(true, .release);
            }
        } else {
            _ = self.polls.fetchAdd(1, .release);
        }
        // Bound the test's idle wait so a lost wake fails instead of hanging.
        const timeout: c_int = @intCast(max_wait_ms orelse 5000);
        const result = mux_c.pp_mux_wait(self.poll_mux, timeout, null);
        if (result < 0 or (max_wait_ms == null and result == 0)) self.failed.store(true, .release);
    }

    fn onReadable(raw: ?*anyopaque, fd: mux_c.pp_fd) callconv(.c) void {
        const self: *DrivenState = @ptrCast(@alignCast(raw.?));
        if (fd != mux_c.pp_mux_wake_descriptor(self.io_mux)) return;
        if (!mux_c.pp_mux_reset_wake(self.io_mux)) self.failed.store(true, .release);
        if (!self.actor.?.isOnQueue()) self.failed.store(true, .release);
        self.io_value = self.value;
        self.nested_io_result = self.actor.?.perform(usize, .{ .echo = 42 }) catch {
            self.failed.store(true, .release);
            return;
        };
        _ = self.io_events.fetchAdd(1, .release);
    }

    fn handle(self: *DrivenState, comptime Result: type, message: Message) CounterError!Result {
        self.handler_thread = std.Thread.getCurrentId();
        if (!self.actor.?.isOnQueue()) self.failed.store(true, .release);
        switch (message) {
            .add => |value| self.value += value,
            .echo => |value| return if (Result == void) {} else value,
            .read => {},
            .nested => return self.actor.?.perform(Result, .{ .echo = 42 }) catch |err| switch (err) {
                error.Closed => unreachable,
                else => |domain_error| return domain_error,
            },
            .fail => return error.Rejected,
            .block => {
                self.job_entered.store(true, .release);
                waitForFlag(&self.release_job) catch self.failed.store(true, .release);
            },
        }
        return if (Result == void) {} else self.value;
    }

    fn finish(self: *DrivenState) void {
        self.finish_count += 1;
        self.finish_on_queue = self.actor.?.isOnQueue();
        self.final_value = self.actor.?.perform(usize, .read) catch {
            self.failed.store(true, .release);
            return;
        };
    }
};

test "actor driver preserves a wake queued between mailbox check and wait" {
    var state = try DrivenState.init();
    defer state.deinit();
    state.hold_next_wait.store(true, .release);
    const actor = try DrivenState.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    defer state.unblock();
    state.actor = actor;
    try waitForFlag(&state.wait_armed);
    // The worker already checked an empty mailbox, but has not entered pp_mux_wait.
    try actor.schedule(.{ .add = 3 });
    try actor.schedule(.fail);
    state.release_wait.store(true, .release);
    try std.testing.expectEqual(@as(usize, 3), try actor.perform(usize, .read));
    try std.testing.expectEqual(@as(usize, 42), try actor.perform(usize, .nested));
    try std.testing.expectError(error.Rejected, actor.perform(usize, .fail));
    actor.shutdown();
    try std.testing.expect(!state.failed.load(.acquire));
    try std.testing.expectEqual(state.handler_thread.?, state.loop_thread.?);
    try std.testing.expectEqual(@as(?usize, 3), state.final_value);
    try std.testing.expect(state.finish_on_queue);
    try std.testing.expectEqual(@as(usize, 1), state.finish_count);
    try std.testing.expectError(error.Closed, actor.schedule(.read));
    try std.testing.expectError(error.Closed, actor.perform(usize, .read));
}

test "actor driver services I/O between queued jobs and permits nested callbacks" {
    var state = try DrivenState.init();
    defer state.deinit();
    const actor = try DrivenState.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    defer state.unblock();
    state.actor = actor;
    try actor.schedule(.block);
    try waitForFlag(&state.job_entered);
    for (0..64) |_| try actor.schedule(.{ .add = 1 });
    try std.testing.expect(mux_c.pp_mux_wake(state.io_mux));
    state.release_job.store(true, .release);
    try std.testing.expectEqual(@as(usize, 64), try actor.perform(usize, .read));
    actor.shutdown();
    try std.testing.expect(!state.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.io_events.load(.acquire));
    try std.testing.expectEqual(@as(?usize, 0), state.io_value);
    try std.testing.expectEqual(@as(?usize, 42), state.nested_io_result);
    try std.testing.expect(state.polls.load(.acquire) > 0);
    try std.testing.expectEqual(state.handler_thread.?, state.loop_thread.?);
}

test "actor driver wakes for shutdown and finishes on the worker" {
    var state = try DrivenState.init();
    defer state.deinit();
    state.hold_next_wait.store(true, .release);
    const actor = try DrivenState.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    defer state.unblock();
    state.actor = actor;
    try waitForFlag(&state.wait_armed);
    const Caller = struct {
        fn shutdown(target: *DrivenState.Actor) void {
            target.shutdown();
        }
    };
    {
        const thread = try std.Thread.spawn(.{}, Caller.shutdown, .{actor});
        defer thread.join();
        defer state.unblock();
        const deadline = source.core.monotonicNs() + 5 * std.time.ns_per_s;
        while (state.wakes.load(.acquire) == 0) {
            if (source.core.monotonicNs() >= deadline) return error.Timeout;
            source.core.sleepMs(1);
        }
        state.release_wait.store(true, .release);
    }
    try std.testing.expect(!state.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.finish_count);
    try std.testing.expect(state.finish_on_queue);
    try std.testing.expectEqual(@as(?usize, 0), state.final_value);
    try std.testing.expect(!actor.isOnQueue());
    actor.shutdown();
    try std.testing.expectEqual(@as(usize, 1), state.finish_count);
}

test "actor driver keeps concurrent synchronous results and errors isolated" {
    const Caller = struct {
        actor: *DrivenState.Actor,
        id: usize,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            for (0..64) |iteration| {
                const expected = self.id * 64 + iteration;
                const actual = self.actor.perform(usize, .{ .echo = expected }) catch |err| {
                    self.failure = err;
                    return;
                };
                if (actual != expected) {
                    self.failure = error.TestExpectedEqual;
                    return;
                }
                std.testing.expectError(error.Rejected, self.actor.perform(usize, .fail)) catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var state = try DrivenState.init();
    defer state.deinit();
    const actor = try DrivenState.Actor.create(std.testing.allocator, &state);
    defer actor.destroy();
    state.actor = actor;
    var callers: [8]Caller = undefined;
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&callers, 0..) |*caller, id| {
            caller.* = .{ .actor = actor, .id = id };
            threads[id] = try std.Thread.spawn(.{}, Caller.run, .{caller});
            started += 1;
        }
    }
    actor.shutdown();
    for (callers) |caller| if (caller.failure) |err| return err;
    try std.testing.expect(!state.failed.load(.acquire));
    try std.testing.expectEqual(state.handler_thread.?, state.loop_thread.?);
}
