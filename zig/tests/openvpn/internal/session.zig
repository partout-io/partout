// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const c_crypto = source.c_crypto;
const net = source.net;
const PRNG = source.openvpn_internal.crypto.PRNG;
const Session = source.openvpn_internal.session.Session;

test "Session declarations are semantically analyzed" {
    std.testing.refAllDecls(Session);
}

test "Session borrows an externally managed Looper" {
    const Callbacks = struct {
        fn onFinish(_: ?*anyopaque, _: ?net.Looper.Failure) void {}

        fn barrier(_: ?*anyopaque) !void {}
    };

    const allocator = std.testing.allocator;
    var looper = try net.Looper.init(allocator, .{
        .on_finish = .{ .callback = Callbacks.onFinish },
    });
    defer looper.deinit();
    try looper.start();
    var looper_started = true;
    defer if (looper_started) looper.stop() catch {};

    const session = try Session.create(
        allocator,
        &looper,
        c_crypto.pp_crypto_fnt_mock(),
        .{},
        null,
        PRNG.system(),
        "",
        .{},
    );
    var session_destroyed = false;
    defer if (!session_destroyed) session.destroy();
    try std.testing.expect(session.looper == &looper);

    session.destroy();
    session_destroyed = true;
    try looper.perform(void, null, Callbacks.barrier);
    try looper.stop();
    looper_started = false;
}
