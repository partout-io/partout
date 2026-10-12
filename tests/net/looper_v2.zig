// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const source = @import("source");
const test_helpers = @import("looper_test_helpers.zig");

const Looper = source.net_looper_v2.Looper;

test "v2-only policy excludes the legacy looper" {
    if (!source.runtime_policy.v2_only) return error.SkipZigTest;
    try std.testing.expect(!@hasDecl(source.runtime_policy.legacy_looper, "Looper"));
}

const TimerProbe = struct {
    calls: usize = 0,
    caller_thread: std.Thread.Id,
    ran_on_caller: bool = false,

    fn run(raw: ?*anyopaque) void {
        const self: *TimerProbe = @ptrCast(@alignCast(raw.?));
        self.ran_on_caller = self.caller_thread == std.Thread.getCurrentId();
        self.calls += 1;
    }
};

const FinishCallProbe = struct {
    calls: usize = 0,

    fn onFinish(raw: ?*anyopaque, _: ?Looper.Failure) void {
        const self: *FinishCallProbe = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
    }
};

test "v2 looper runs and cancels timers on its caller" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var finish = FinishCallProbe{};
    var looper = try Looper.init(std.testing.allocator, .{
        .mux = wake.handle,
        .on_finish = .{ .context = &finish, .callback = FinishCallProbe.onFinish },
    });
    defer looper.deinit();
    var timer = Looper.Timer{};
    var probe = TimerProbe{ .caller_thread = std.Thread.getCurrentId() };
    const task: Looper.TimedTask = .{ .context = &probe, .callback = TimerProbe.run };
    try looper.scheduleTimer(&timer, 1, task);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expect(try test_helpers.poll(&looper, 100));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.ran_on_caller);

    try looper.scheduleTimer(&timer, 0, task);
    looper.cancelTimer(&timer);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try looper.scheduleTimer(&timer, 1000, task);
    try looper.scheduleTimer(&timer, 0, task);
    try std.testing.expect(try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);

    try looper.scheduleTimer(&timer, 0, task);
    try looper.stop();
    try looper.stop();
    try std.testing.expectEqual(@as(usize, 0), finish.calls);
    try std.testing.expect(!try test_helpers.poll(&looper, 0));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectError(error.LooperUnavailable, looper.scheduleTimer(&timer, 0, task));
}
