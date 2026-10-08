// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");
const c = source.ffi.io;
const Waiter = source.net_waiter.Waiter;

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

    try std.testing.expect(waiter.mux != null);
    try std.testing.expect(c.pp_mux_wake(waiter.mux));
    try std.testing.expect(!try waiter.wait(null, false, null));
    try std.testing.expectEqual(@as(usize, 0), waiter.pending);
}
