// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const io = source.net_io;
const net = source.net;
const AuthToken = source.openvpn_internal.auth.AuthToken;
const PRNG = source.openvpn_internal.crypto.PRNG;
const Session = source.openvpn_internal.session.Session;
const SessionError = source.openvpn_internal.session.SessionError;
const session_testing = source.openvpn_internal.session.testing;

const MockIO = struct {
    cleanup_count: usize = 0,

    fn interface(self: *MockIO) io.IOInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setEventMask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
    fn resetEvents(_: *anyopaque) io.Error!void {}
    fn read(_: *anyopaque, _: []u8) io.Error!?usize {
        return null;
    }
    fn write(_: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
        return data.len - offset;
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *MockIO = @ptrCast(@alignCast(raw));
        self.cleanup_count += 1;
    }
    fn lastErrorCode(_: *anyopaque) c_int {
        return 0;
    }

    const vtable = io.IOInterface.VTable{
        .set_event_mask = setEventMask,
        .reset_events = resetEvents,
        .read = read,
        .write = write,
        .cleanup = cleanup,
        .last_error_code = lastErrorCode,
    };
};

test "Session declarations are semantically analyzed" {
    std.testing.refAllDecls(Session);
}

test "Session borrows an externally managed Looper" {
    const Callbacks = struct {
        fn onFinish(_: ?*anyopaque, _: ?net.Looper.Failure) void {}

        fn barrier(_: ?*anyopaque) !void {}

        fn established(
            _: ?*anyopaque,
            _: *anyopaque,
            _: source.core.api.ExtendedEndpoint,
            _: *const source.core.api.OpenVPNConfiguration,
        ) void {}

        fn failed(_: ?*anyopaque, _: *anyopaque, _: SessionError) void {}

        fn dataCount(_: ?*anyopaque, _: *anyopaque, _: source.core.api.DataCount) void {}
    };

    const allocator = std.testing.allocator;
    var looper = try net.Looper.init(allocator, .{
        .on_finish = .{ .callback = Callbacks.onFinish },
    });
    defer looper.deinit();
    try looper.start();
    var looper_started = true;
    defer if (looper_started) looper.stop() catch {};

    var auth_token = AuthToken{};
    defer auth_token.deinit();
    const session = try Session.create(allocator, .{
        .looper = &looper,
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
    try std.testing.expect(session.looper == &looper);

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
            _: *anyopaque,
            _: source.core.api.ExtendedEndpoint,
            _: *const source.core.api.OpenVPNConfiguration,
        ) void {}

        fn failed(raw: ?*anyopaque, _: *anyopaque, cause: SessionError) void {
            const state: *State = @ptrCast(@alignCast(raw.?));
            state.count += 1;
            state.last = cause;
        }

        fn dataCount(_: ?*anyopaque, _: *anyopaque, _: source.core.api.DataCount) void {}
    };

    const allocator = std.testing.allocator;
    var event_state = RecordingEvents.State{};
    var looper = try net.Looper.init(allocator, .{
        .on_finish = .{ .callback = struct {
            fn call(_: ?*anyopaque, _: ?net.Looper.Failure) void {}
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
            .context = &event_state,
            .established = RecordingEvents.established,
            .failed = RecordingEvents.failed,
            .data_count = RecordingEvents.dataCount,
        },
        .looper = &looper,
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

test "Session releases a link processor once when attach fails" {
    const Callbacks = struct {
        fn established(
            _: ?*anyopaque,
            _: *anyopaque,
            _: source.core.api.ExtendedEndpoint,
            _: *const source.core.api.OpenVPNConfiguration,
        ) void {}

        fn failed(_: ?*anyopaque, _: *anyopaque, _: SessionError) void {}
        fn dataCount(_: ?*anyopaque, _: *anyopaque, _: source.core.api.DataCount) void {}
    };

    const allocator = std.testing.allocator;
    var looper = try net.Looper.init(allocator, .{
        .on_finish = .{ .callback = struct {
            fn call(_: ?*anyopaque, _: ?net.Looper.Failure) void {}
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
            .established = Callbacks.established,
            .failed = Callbacks.failed,
            .data_count = Callbacks.dataCount,
        },
        .looper = &looper,
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

    var mock_io = MockIO{};
    const endpoint = source.core.api.ExtendedEndpoint.init(
        "192.0.2.1",
        .init(.udp, 1194),
    ).?;
    try std.testing.expectError(
        error.LinkFailure,
        session.setLink(.{ .fd = -1, .io = mock_io.interface() }, endpoint),
    );
    try std.testing.expectEqual(@as(usize, 1), mock_io.cleanup_count);

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
