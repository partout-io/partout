// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;

const AtomicBool = std.atomic.Value(bool);

fn waitUntil(value: *const AtomicBool) void {
    while (!value.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

fn settleScheduler() void {
    for (0..1000) |_| {
        std.Thread.yield() catch {};
    }
}

fn storeTrue(ctx: ?*anyopaque) void {
    const value: *AtomicBool = @ptrCast(@alignCast(ctx.?));
    value.store(true, .release);
}

const ThreadRecorder = struct {
    mutex: core.Mutex = .{},
    count: usize = 0,
    first: ?std.Thread.Id = null,
    second: ?std.Thread.Id = null,
    first_did_run: AtomicBool = AtomicBool.init(false),
    second_did_run: AtomicBool = AtomicBool.init(false),

    fn deinit(self: *ThreadRecorder) void {
        self.mutex.deinit();
    }

    fn record(ctx: ?*anyopaque) void {
        const self: *ThreadRecorder = @ptrCast(@alignCast(ctx.?));

        self.mutex.lock();
        self.count += 1;
        switch (self.count) {
            1 => {
                self.first = std.Thread.getCurrentId();
                self.first_did_run.store(true, .release);
            },
            2 => {
                self.second = std.Thread.getCurrentId();
                self.second_did_run.store(true, .release);
            },
            else => {},
        }
        self.mutex.unlock();
    }
};

const BlockingRecorder = struct {
    mutex: core.Mutex = .{},
    count: usize = 0,
    first_did_start: AtomicBool = AtomicBool.init(false),
    first_can_finish: AtomicBool = AtomicBool.init(false),
    second_did_run: AtomicBool = AtomicBool.init(false),

    fn deinit(self: *BlockingRecorder) void {
        self.mutex.deinit();
    }

    fn record(ctx: ?*anyopaque) void {
        const self: *BlockingRecorder = @ptrCast(@alignCast(ctx.?));

        self.mutex.lock();
        self.count += 1;
        const count = self.count;
        self.mutex.unlock();

        switch (count) {
            1 => {
                self.first_did_start.store(true, .release);
                waitUntil(&self.first_can_finish);
            },
            2 => self.second_did_run.store(true, .release),
            else => {},
        }
    }
};

test "drainer waits until in-flight work completes" {
    const Worker = struct {
        mutex: *core.Mutex,
        drainer: *core.Drainer,
        started: *AtomicBool,
        release: *AtomicBool,
        completed: *AtomicBool,

        fn run(self: @This()) void {
            self.mutex.lock();
            self.drainer.enter();
            self.mutex.unlock();

            self.started.store(true, .release);
            waitUntil(self.release);
            self.drainer.leave(self.mutex);
            self.completed.store(true, .release);
        }
    };
    const Drain = struct {
        mutex: *core.Mutex,
        drainer: *core.Drainer,
        started: *AtomicBool,
        completed: *AtomicBool,

        fn run(self: @This()) void {
            self.mutex.lock();
            self.started.store(true, .release);
            self.drainer.drain(self.mutex);
            self.mutex.unlock();
            self.completed.store(true, .release);
        }
    };

    var mutex = core.Mutex{};
    defer mutex.deinit();
    var drainer = core.Drainer{};
    defer drainer.deinit();
    var worker_started = AtomicBool.init(false);
    var worker_release = AtomicBool.init(false);
    var worker_completed = AtomicBool.init(false);
    var drain_started = AtomicBool.init(false);
    var drain_completed = AtomicBool.init(false);

    var worker_thread = try std.Thread.spawn(.{}, Worker.run, .{Worker{
        .mutex = &mutex,
        .drainer = &drainer,
        .started = &worker_started,
        .release = &worker_release,
        .completed = &worker_completed,
    }});
    waitUntil(&worker_started);

    var drain_thread = try std.Thread.spawn(.{}, Drain.run, .{Drain{
        .mutex = &mutex,
        .drainer = &drainer,
        .started = &drain_started,
        .completed = &drain_completed,
    }});
    waitUntil(&drain_started);
    settleScheduler();

    if (drain_completed.load(.acquire)) {
        worker_release.store(true, .release);
        worker_thread.join();
        drain_thread.join();
        return error.TestUnexpectedResult;
    }

    worker_release.store(true, .release);
    worker_thread.join();
    drain_thread.join();

    try std.testing.expect(worker_completed.load(.acquire));
    try std.testing.expect(drain_completed.load(.acquire));
}

test "RunAfter runs callback after delay" {
    var did_run = AtomicBool.init(false);
    var run_after = core.RunAfter{};
    try run_after.init(1, storeTrue, &did_run);
    defer run_after.deinit();

    waitUntil(&did_run);
}

test "RunAfter cancel prevents callback" {
    var did_run = AtomicBool.init(false);
    var run_after = core.RunAfter{};
    try run_after.init(100, storeTrue, &did_run);

    run_after.cancel();
    run_after.deinit();

    try std.testing.expect(!did_run.load(.acquire));
}

test "RunAfter init cancels previous callback" {
    var first_did_run = AtomicBool.init(false);
    var second_did_run = AtomicBool.init(false);
    var run_after = core.RunAfter{};
    try run_after.init(100, storeTrue, &first_did_run);
    try run_after.init(1, storeTrue, &second_did_run);
    defer run_after.deinit();

    waitUntil(&second_did_run);
    try std.testing.expect(!first_did_run.load(.acquire));
}

test "RunAfter reuses worker thread" {
    var recorder = ThreadRecorder{};
    defer recorder.deinit();
    var run_after = core.RunAfter{};
    defer run_after.deinit();

    try run_after.init(1, ThreadRecorder.record, &recorder);
    waitUntil(&recorder.first_did_run);

    try run_after.init(1, ThreadRecorder.record, &recorder);
    waitUntil(&recorder.second_did_run);

    recorder.mutex.lock();
    defer recorder.mutex.unlock();

    try std.testing.expectEqual(recorder.first.?, recorder.second.?);
}

test "RunAfter can reschedule while callback is running" {
    var recorder = BlockingRecorder{};
    defer recorder.deinit();
    var run_after = core.RunAfter{};
    defer run_after.deinit();
    defer recorder.first_can_finish.store(true, .release);

    try run_after.init(1, BlockingRecorder.record, &recorder);
    waitUntil(&recorder.first_did_start);

    try run_after.init(1, BlockingRecorder.record, &recorder);
    settleScheduler();
    try std.testing.expect(!recorder.second_did_run.load(.acquire));

    recorder.first_can_finish.store(true, .release);
    waitUntil(&recorder.second_did_run);
}
