// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");
const io = source.net_io_common;
const c = io.io_c;
const Waiter = io.Waiter;

fn failWait(_: c.pp_fd, _: bool, _: c.pp_fd) callconv(.c) c_int {
    return -1;
}

test "waiter returns a named failure and completes cleanup" {
    var waiter = Waiter.init() orelse return error.MuxCreationFailed;
    waiter.test_wait_once = failWait;
    defer waiter.deinit();
    var lock: source.core.Mutex = .{};
    defer lock.deinit();
    lock.lock();
    defer lock.unlock();

    try std.testing.expectError(error.WaitFailed, waiter.wait(null, false, &lock));
    try std.testing.expectEqual(@as(usize, 0), waiter.pending);
}

test "waiter initializes its mux before waiting" {
    var waiter = Waiter.init() orelse return error.MuxCreationFailed;
    defer waiter.deinit();
    var lock: source.core.Mutex = .{};
    defer lock.deinit();
    lock.lock();
    defer lock.unlock();

    try std.testing.expect(waiter.mux != null);
    try std.testing.expect(c.pp_mux_wake(waiter.mux));
    try std.testing.expect(!try waiter.wait(null, false, &lock));
    try std.testing.expectEqual(@as(usize, 0), waiter.pending);
}

const WakeRegression = struct {
    var hold_original = std.atomic.Value(bool).init(true);
    var original_returned = std.atomic.Value(bool).init(false);
    var native_calls = std.atomic.Value(usize).init(0);

    fn waitOnce(fd: c.pp_fd, writing: bool, wake_fd: c.pp_fd) callconv(.c) c_int {
        _ = native_calls.fetchAdd(1, .seq_cst);
        const result = c.pp_mux_wait_once(fd, writing, wake_fd);
        if (writing) {
            original_returned.store(true, .seq_cst);
            while (hold_original.load(.seq_cst)) source.core.sleepMs(1);
        }
        return result;
    }

    const Request = struct {
        waiter: *Waiter,
        lock: *source.core.Mutex,
        writing: bool = false,
        retry: bool = false,
        result: ?bool = null,
        failed: bool = false,

        fn run(self: *Request) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.result = self.waiter.wait(null, self.writing, self.lock) catch {
                self.failed = true;
                return;
            };
            if (self.retry) self.result = self.waiter.wait(null, false, self.lock) catch {
                self.failed = true;
                return;
            };
        }
    };

    fn awaitPending(waiter: *Waiter, lock: *source.core.Mutex, pending: usize, polling: usize) !void {
        for (0..3000) |_| {
            lock.lock();
            const ready = waiter.pending == pending and waiter.pollers.in_flight == polling;
            lock.unlock();
            if (ready) return;
            source.core.sleepMs(1);
        }
        return error.TestUnexpectedResult;
    }
};

test "waiter retries cannot retain a shared wake while original pollers drain" {
    for ([_]bool{ false, true }) |release| {
        WakeRegression.hold_original.store(true, .seq_cst);
        WakeRegression.original_returned.store(false, .seq_cst);
        WakeRegression.native_calls.store(0, .seq_cst);
        var waiter = Waiter.init() orelse return error.MuxCreationFailed;
        defer if (waiter.mux != null) waiter.deinit();
        waiter.test_wait_once = WakeRegression.waitOnce;
        var lock: source.core.Mutex = .{};
        defer lock.deinit();
        var retrying = WakeRegression.Request{ .waiter = &waiter, .lock = &lock, .retry = true };
        var original = WakeRegression.Request{ .waiter = &waiter, .lock = &lock, .writing = true };
        const first = try std.Thread.spawn(.{}, WakeRegression.Request.run, .{&retrying});
        var first_joined = false;
        errdefer if (!first_joined) {
            WakeRegression.hold_original.store(false, .seq_cst);
            lock.lock();
            waiter.wake();
            lock.unlock();
            first.join();
        };
        const second = try std.Thread.spawn(.{}, WakeRegression.Request.run, .{&original});
        var second_joined = false;
        errdefer if (!second_joined) {
            WakeRegression.hold_original.store(false, .seq_cst);
            lock.lock();
            waiter.wake();
            lock.unlock();
            second.join();
        };
        try WakeRegression.awaitPending(&waiter, &lock, 2, 2);
        lock.lock();
        waiter.wake();
        waiter.wake(); // Duplicate wake must not extend the cohort.
        lock.unlock();
        try WakeRegression.awaitPending(&waiter, &lock, 2, 1);
        for (0..3000) |_| {
            if (WakeRegression.original_returned.load(.seq_cst)) break;
            source.core.sleepMs(1);
        }
        try std.testing.expect(WakeRegression.original_returned.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 2), WakeRegression.native_calls.load(.seq_cst));
        if (release) {
            lock.lock();
            waiter.deinit();
            lock.unlock();
        }
        WakeRegression.hold_original.store(false, .seq_cst);
        first.join();
        first_joined = true;
        second.join();
        second_joined = true;
        try std.testing.expect(!retrying.failed and !original.failed);
        try std.testing.expectEqual(false, retrying.result.?);
        try std.testing.expectEqual(false, original.result.?);
        try std.testing.expectEqual(@as(usize, 0), waiter.pending);
        try std.testing.expect(!waiter.waking);

        if (release) {
            try std.testing.expect(waiter.mux == null);
            continue;
        }

        // A subsequent generation must really block, rather than observe stale wake.
        var fresh = WakeRegression.Request{ .waiter = &waiter, .lock = &lock };
        const third = try std.Thread.spawn(.{}, WakeRegression.Request.run, .{&fresh});
        defer {
            lock.lock();
            waiter.wake();
            lock.unlock();
            third.join();
        }
        try WakeRegression.awaitPending(&waiter, &lock, 1, 1);
    }
}
