// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const source = @import("source");

const AtomicBool = std.atomic.Value(bool);
const Looper = source.net_looper.Looper;

test "v2-only policy excludes the legacy looper" {
    if (!source.runtime_policy.v2_only) return error.SkipZigTest;
    const Callbacks = struct {
        fn finish(_: ?*anyopaque, _: ?Looper.Failure) void {}
    };
    inline for (.{ Looper.init, Looper.initExperimental }) |init| {
        var looper = try init(std.testing.allocator, .{ .on_finish = .{ .callback = Callbacks.finish } });
        defer looper.deinit();
        try std.testing.expect(!@hasField(@TypeOf(looper.implementation), "legacy"));
        try std.testing.expect(looper.implementation == .experimental);
    }
}

fn waitUntil(value: *const AtomicBool) void {
    while (!value.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

fn noopTask(_: ?*anyopaque) anyerror!void {}

fn returnFortyTwo(_: ?*anyopaque) anyerror!u8 {
    return 42;
}

fn scheduleTimer(
    looper: *Looper,
    timer: *Looper.Timer,
    delay_ms: u64,
    task: Looper.TimedTask,
) !void {
    const Request = struct {
        looper: *Looper,
        timer: *Looper.Timer,
        delay_ms: u64,
        task: Looper.TimedTask,

        fn run(raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.looper.scheduleReplacing(
                self.timer,
                self.delay_ms,
                self.task,
            );
        }
    };
    var request = Request{
        .looper = looper,
        .timer = timer,
        .delay_ms = delay_ms,
        .task = task,
    };
    try looper.performTask(.{ .context = &request, .callback = Request.run });
}

fn cancelTimer(looper: *Looper, timer: *Looper.Timer) !void {
    const Request = struct {
        looper: *Looper,
        timer: *Looper.Timer,

        fn run(raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.looper.cancelTimer(self.timer);
        }
    };
    var request = Request{ .looper = looper, .timer = timer };
    try looper.performTask(.{ .context = &request, .callback = Request.run });
}

const TimerProbe = struct {
    looper: *Looper,
    did_run: AtomicBool = AtomicBool.init(false),
    ran_on_looper: AtomicBool = AtomicBool.init(false),

    fn run(raw: ?*anyopaque) void {
        const self: *TimerProbe = @ptrCast(@alignCast(raw.?));
        self.ran_on_looper.store(self.looper.isOnQueue(), .release);
        self.did_run.store(true, .release);
    }
};

const FinishCallProbe = struct {
    called: AtomicBool = AtomicBool.init(false),

    fn onFinish(raw: ?*anyopaque, _: ?Looper.Failure) void {
        const self: *FinishCallProbe = @ptrCast(@alignCast(raw.?));
        self.called.store(true, .release);
    }
};

test "experimental looper dispatches tasks and timers through the shared API" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var finish = FinishCallProbe{};
    var looper = try Looper.initExperimental(std.testing.allocator, .{
        .on_finish = .{ .context = &finish, .callback = FinishCallProbe.onFinish },
    });
    defer looper.deinit();
    try std.testing.expect(looper.implementation == .experimental);
    try looper.start();
    var stopped = false;
    defer if (!stopped) looper.stop() catch {};
    try std.testing.expectEqual(@as(u8, 42), try looper.perform(u8, null, returnFortyTwo));

    var timer = Looper.Timer{};
    var probe = TimerProbe{ .looper = &looper };
    try scheduleTimer(&looper, &timer, 1, .{ .context = &probe, .callback = TimerProbe.run });
    waitUntil(&probe.did_run);
    try std.testing.expect(probe.ran_on_looper.load(.acquire));
    try cancelTimer(&looper, &timer);
    try looper.stop();
    stopped = true;
    try std.testing.expect(finish.called.load(.acquire));
    try std.testing.expectError(error.LooperUnavailable, looper.performTask(.{ .callback = noopTask }));
}
