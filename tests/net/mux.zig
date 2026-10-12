// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const mux_c = @import("source").ffi.io;

test "mux wait observes explicit wake" {
    const mux = mux_c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer mux_c.pp_mux_free(mux);

    // Queue the wake first so the test is deterministic without thread timing.
    try std.testing.expect(mux_c.pp_mux_wake(mux));
    try std.testing.expectEqual(@as(c_int, 1), mux_c.pp_mux_wait(mux, -1, null));
}

test "mux wait preserves the null-mux error" {
    try std.testing.expectEqual(
        mux_c.PPMuxErrorNull,
        mux_c.pp_mux_wait(null, -1, null),
    );
}

test "mux wait supports polling and timer timeouts" {
    const mux = mux_c.pp_mux_create(1) orelse return error.MuxCreationFailed;
    defer mux_c.pp_mux_free(mux);
    var code: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 0), mux_c.pp_mux_wait(mux, 0, &code));
    try std.testing.expectEqual(@as(c_int, 0), mux_c.pp_mux_wait(mux, 2, &code));
    try std.testing.expectEqual(@as(c_int, 0), code);
    try std.testing.expect(mux_c.pp_mux_wake(mux));
    try std.testing.expectEqual(@as(c_int, 1), mux_c.pp_mux_wait(mux, 1000, &code));
    try std.testing.expectEqual(@as(c_int, 0), mux_c.pp_mux_wait(mux, 0, &code));
}
