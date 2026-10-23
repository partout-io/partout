// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const builtin = @import("builtin");
const source = @import("source");
const test_helpers = @import("../../net/looper_test_helpers.zig");

const net = source.net;
const io = source.net_io;

const AuthToken = source.openvpn_internal.auth.AuthToken;
const Looper = source.net_looper.Looper;
const PRNG = source.openvpn_internal.crypto.PRNG;
const Session = source.openvpn_internal.session.Session;
const SessionError = source.openvpn_internal.session.SessionError;
const session_testing = source.openvpn_internal.session.testing;

test "Session declarations are semantically analyzed" {
    std.testing.refAllDecls(Session);
}

test "Session uses externally supplied I/O callbacks" {
    // WindowsLooper does not implement caller-driven I/O yet.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Callbacks = struct {
        fn established(
            _: ?*anyopaque,
            _: source.net.SocketEndpoint,
            _: *const source.core.api.OpenVPNConfiguration,
        ) void {}

        fn failed(_: ?*anyopaque, _: SessionError) void {}

        fn dataCount(_: ?*anyopaque, _: source.core.api.DataCount) void {}
    };

    const allocator = std.testing.allocator;
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var looper = try Looper.init(allocator, .{
        .mux = wake.handle,
    });
    defer looper.deinit();
    defer looper.stop() catch {};

    var auth_token = AuthToken{};
    defer auth_token.deinit();
    const session = try Session.create(allocator, .{
        .writer = net.ConnectionWriter.init(&looper, &writer_vtable),
        .remote_endpoint = try source.net.SocketEndpoint.init(source.core.api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?),
        .events = .{
            .established = Callbacks.established,
            .failed = Callbacks.failed,
            .data_count = Callbacks.dataCount,
        },
        .configuration = .{},
        .credentials = null,
        .auth_token = &auth_token,
        .prng = PRNG.system(),
        .caches_directory = "",
        .ca_filename = "11111111-1111-4111-8111-111111111111-ca.pem",
        .options = .{ .backend = .mock },
    });
    var session_destroyed = false;
    defer if (!session_destroyed) session.destroy();
    try std.testing.expect(session.writer.ptr == @as(*anyopaque, &looper));

    session.destroy();
    session_destroyed = true;
    var failure: ?io.Failure = null;
    try std.testing.expect(looper.impl.loopOnce(0, &failure));
    try std.testing.expect(failure == null);
    try looper.stop();
}

test "Session reports protocol failures without owning shutdown policy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const RecordingEvents = struct {
        const State = struct {
            count: usize = 0,
            last: ?SessionError = null,
        };

        fn established(
            _: ?*anyopaque,
            _: source.net.SocketEndpoint,
            _: *const source.core.api.OpenVPNConfiguration,
        ) void {}

        fn failed(raw: ?*anyopaque, cause: SessionError) void {
            const state: *State = @ptrCast(@alignCast(raw.?));
            state.count += 1;
            state.last = cause;
        }

        fn dataCount(_: ?*anyopaque, _: source.core.api.DataCount) void {}
    };

    const allocator = std.testing.allocator;
    var event_state = RecordingEvents.State{};
    const wake = try test_helpers.Mux.init();
    defer wake.deinit();
    var looper = try Looper.init(allocator, .{
        .mux = wake.handle,
    });
    defer looper.deinit();
    defer looper.stop() catch {};

    var auth_token = AuthToken{};
    defer auth_token.deinit();
    const session = try Session.create(allocator, .{
        .events = .{
            .ctx = &event_state,
            .established = RecordingEvents.established,
            .failed = RecordingEvents.failed,
            .data_count = RecordingEvents.dataCount,
        },
        .writer = net.ConnectionWriter.init(&looper, &writer_vtable),
        .remote_endpoint = try source.net.SocketEndpoint.init(source.core.api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?),
        .configuration = .{},
        .credentials = null,
        .auth_token = &auth_token,
        .prng = PRNG.system(),
        .caches_directory = "",
        .ca_filename = "11111111-1111-4111-8111-111111111111-ca.pem",
        .options = .{ .backend = .mock },
    });
    var session_destroyed = false;
    defer if (!session_destroyed) session.destroy();

    session_testing.reportFailure(session, error.SessionStale);
    session_testing.reportFailure(session, error.TLSFailure);
    try std.testing.expectEqual(@as(usize, 2), event_state.count);
    try std.testing.expectEqual(error.TLSFailure, event_state.last.?);

    session.destroy();
    session_destroyed = true;
    try looper.stop();
}

test "session sends exit notification only for graceful shutdowns" {
    try std.testing.expect(session_testing.shouldSendExitNotification(true));
    try std.testing.expect(!session_testing.shouldSendExitNotification(false));
}

test "Session preserves callback failures and classifies native side failures" {
    const classify = session_testing.sideFailureError;

    try std.testing.expectEqual(
        error.BadCredentialsWithLocalOptions,
        classify(.{ .user = error.BadCredentialsWithLocalOptions }, error.LinkFailure),
    );
    try std.testing.expectEqual(
        error.LinkFailure,
        classify(.{ .wait = 1 }, error.LinkFailure),
    );
    try std.testing.expectEqual(
        error.TunnelFailure,
        classify(.{ .system = error.EndOfStream }, error.TunnelFailure),
    );
    try std.testing.expectEqual(
        error.LinkFailure,
        classify(.{ .io = .{
            .side = .link,
            .cause = error.LibcFailure,
            .code = 5,
        } }, error.LinkFailure),
    );
}

const writer_vtable: net.ConnectionWriter.VTable = .{
    .write_packets = writePackets,
    .schedule_timer = scheduleTimer,
    .cancel_timer = cancelTimer,
};

fn writePackets(raw: *anyopaque, packets: io.Packets, side: io.Side, destination: ?io.SocketAddress) (io.SubmissionError || error{MissingDestination})!void {
    const looper: *Looper = @ptrCast(@alignCast(raw));
    looper.write(packets, side, destination) catch |err| switch (err) {
        error.SideNotAttached, error.InvalidBuffers => {},
        else => |failure| return failure,
    };
}

fn scheduleTimer(raw: *anyopaque, timer: *io.Timer, delay_ms: u64, task: io.TimedTask) io.SubmissionError!void {
    const looper: *Looper = @ptrCast(@alignCast(raw));
    return looper.scheduleTimer(timer, delay_ms, task);
}

fn cancelTimer(raw: *anyopaque, timer: *io.Timer) void {
    const looper: *Looper = @ptrCast(@alignCast(raw));
    looper.cancelTimer(timer);
}
