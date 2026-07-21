// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");

const c = @cImport({
    @cInclude("portable/mux.h");
});

fn ignoreSignal(_: std.posix.SIG) callconv(.c) void {}

const PollInterruptor = struct {
    target: std.c.pthread_t,
    start: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    sent: std.atomic.Value(bool) = .init(false),

    fn run(self: *PollInterruptor) void {
        self.ready.store(true, .release);
        while (!self.start.load(.acquire)) std.Thread.yield() catch {};
        source.core.sleepMs(150);
        self.sent.store(std.c.pthread_kill(self.target, .USR1) == 0, .release);
    }
};

test "mux timeout wait expires without reporting an error" {
    const mux = c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer c.pp_mux_free(mux);

    var error_code: c_int = 1234;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.pp_mux_wait_timeout(mux, &error_code, 0),
    );
    try std.testing.expectEqual(@as(c_int, 1234), error_code);

    try std.testing.expectEqual(
        @as(c_int, 0),
        c.pp_mux_wait_timeout(mux, &error_code, 1),
    );
    try std.testing.expectEqual(@as(c_int, 1234), error_code);
}

test "mux timeout preserves its deadline across interrupted waits" {
    if (!std.Thread.use_pthreads) return error.SkipZigTest;

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = ignoreSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR1, &action, &previous_action);
    defer std.posix.sigaction(.USR1, &previous_action, null);

    const mux = c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer c.pp_mux_free(mux);

    var interruptor = PollInterruptor{ .target = std.c.pthread_self() };
    const interrupt_thread = try std.Thread.spawn(.{}, PollInterruptor.run, .{&interruptor});
    defer interrupt_thread.join();
    while (!interruptor.ready.load(.acquire)) std.Thread.yield() catch {};

    const started_ns = source.core.concurrency.monotonicNs();
    interruptor.start.store(true, .release);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.pp_mux_wait_timeout(mux, null, 250),
    );
    const elapsed_ms = (source.core.concurrency.monotonicNs() - started_ns) /
        std.time.ns_per_ms;

    try std.testing.expect(interruptor.sent.load(.acquire));
    try std.testing.expect(elapsed_ms >= 225);
    // Restarting poll with the original timeout would take roughly 400 ms.
    try std.testing.expect(elapsed_ms < 350);
}

test "mux timeout wait observes explicit wake" {
    const mux = c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer c.pp_mux_free(mux);

    try std.testing.expect(c.pp_mux_wake(mux));
    try std.testing.expectEqual(
        @as(c_int, 1),
        c.pp_mux_wait_timeout(mux, null, 100),
    );
}

test "legacy mux wait remains an indefinitely blocking wrapper" {
    const mux = c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer c.pp_mux_free(mux);

    // Queue the wake first so the test can exercise the compatibility entry
    // point deterministically without relying on thread timing.
    try std.testing.expect(c.pp_mux_wake(mux));
    try std.testing.expectEqual(@as(c_int, 1), c.pp_mux_wait(mux, null));
}

test "mux timeout wait preserves the null-mux error" {
    try std.testing.expectEqual(
        c.PPMuxErrorNull,
        c.pp_mux_wait_timeout(null, null, 0),
    );
}
