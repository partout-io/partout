// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const builtin = @import("builtin");
const source = @import("source");

const net = source.net;

const AuthToken = source.openvpn_internal.auth.AuthToken;
const Looper = source.net_looper_v2.Looper;
const PRNG = source.openvpn_internal.crypto.PRNG;
const Session = source.openvpn_internal.session_v2.Session;
const SessionError = source.openvpn_internal.session_v2.SessionError;
const session_testing = source.openvpn_internal.session_v2.testing;

test "Session declarations are semantically analyzed" {
    std.testing.refAllDecls(Session);
}

test "v2-only policy selects OpenVPN session v2" {
    if (!source.runtime_policy.v2_only) return error.SkipZigTest;
    try std.testing.expect(source.openvpn_internal.session.Session == Session);
    try std.testing.expect(!@hasDecl(Session, "setLink"));
    try std.testing.expect(@hasDecl(Session, "submitPackets"));
}

test "Session uses externally supplied I/O callbacks" {
    // FIXME: ###, Enable when WindowsLooper implements queue dispatch.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Callbacks = struct {
        fn onFinish(_: ?*anyopaque, _: ?Looper.Failure) void {}

        fn barrier(_: ?*anyopaque) !void {}

        fn established(
            _: ?*anyopaque,
            _: source.net.SocketEndpoint,
            _: *const source.core.api.OpenVPNConfiguration,
        ) void {}

        fn failed(_: ?*anyopaque, _: SessionError) void {}

        fn dataCount(_: ?*anyopaque, _: source.core.api.DataCount) void {}
    };

    const allocator = std.testing.allocator;
    var looper = try Looper.init(allocator, .{
        .on_finish = .{ .callback = Callbacks.onFinish },
    });
    defer looper.deinit();
    try looper.start();
    var looper_started = true;
    defer if (looper_started) looper.stop() catch {};

    var auth_token = AuthToken{};
    defer auth_token.deinit();
    const session = try Session.create(allocator, .{
        .connection_events = connectionEvents(&looper),
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
    try std.testing.expect(session.connection_events.ctx == @as(*anyopaque, &looper));

    session.destroy();
    session_destroyed = true;
    try looper.perform(void, null, Callbacks.barrier);
    try looper.stop();
    looper_started = false;
}

test "Session reports protocol failures without owning shutdown policy" {
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
    var looper = try Looper.init(allocator, .{
        .on_finish = .{ .callback = struct {
            fn call(_: ?*anyopaque, _: ?Looper.Failure) void {}
        }.call },
    });
    defer looper.deinit();
    try looper.start();
    var looper_started = true;
    defer if (looper_started) looper.stop() catch {};

    var auth_token = AuthToken{};
    defer auth_token.deinit();
    const session = try Session.create(allocator, .{
        .events = .{
            .ctx = &event_state,
            .established = RecordingEvents.established,
            .failed = RecordingEvents.failed,
            .data_count = RecordingEvents.dataCount,
        },
        .connection_events = connectionEvents(&looper),
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
    looper_started = false;
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

fn connectionEvents(looper: *Looper) net.Connection.Events {
    return .{
        .ctx = looper,
        .write_packets = writePackets,
        .write_out_of_band = writeOutOfBand,
        .schedule_timer = scheduleTimer,
        .cancel_timer = cancelTimer,
        .data_count = ignoreDataCount,
        .status = ignoreStatus,
        .last_error = ignoreLastError,
        .cancel = ignoreError,
    };
}
fn writePackets(raw: *anyopaque, packets: Looper.Packets, side: net.Side, destination: ?net.SocketAddress) (Looper.SubmissionError || error{MissingDestination})!void {
    const looper: *Looper = @ptrCast(@alignCast(raw));
    return source.net_daemon_helpers.WriteCopy.submit(looper.allocator, looper, packets, side, destination);
}
fn writeOutOfBand(raw: *anyopaque, packets: Looper.Packets, side: net.Side, destination: ?net.SocketAddress) Looper.WriteOOBError!void {
    const looper: *Looper = @ptrCast(@alignCast(raw));
    return looper.writeOutOfBand(packets, side, destination);
}
fn scheduleTimer(raw: *anyopaque, timer: *Looper.Timer, delay_ms: u64, task: Looper.TimedTask) Looper.SubmissionError!void {
    const looper: *Looper = @ptrCast(@alignCast(raw));
    return looper.scheduleReplacing(timer, delay_ms, task);
}
fn cancelTimer(raw: *anyopaque, timer: *Looper.Timer) void {
    const looper: *Looper = @ptrCast(@alignCast(raw));
    looper.cancelTimer(timer);
}
fn ignoreDataCount(_: *anyopaque, _: source.core.api.DataCount) void {}
fn ignoreStatus(_: *anyopaque, _: source.core.api.ConnectionStatus) void {}
fn ignoreError(_: *anyopaque, _: ?source.core.api.PartoutErrorPair) void {}

fn ignoreLastError(_: *anyopaque, _: source.core.api.PartoutErrorPair) void {}
