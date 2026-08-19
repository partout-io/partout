// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const io = @import("source").net_io;
const platform_source = @import("source").net_platform;
const c = @import("source").c_exports.io;

const Platform = platform_source.Platform;
const ReachabilityInfo = io.ReachabilityInfo;
const SocketDescriptor = io.SocketDescriptor;

const api = core.api;
const platformConfigureSocket = platform_source.testing.platformConfigureSocket;
const reachable = io.testing.reachable;
const socketOptions = platform_source.testing.socketOptions;

const TunnelCommitRecorder = struct {
    calls: usize = 0,
    received_settings_only_info: bool = false,
    environment_set_calls: usize = 0,
    environment_remove_calls: usize = 0,
    received_environment_key: bool = false,
    received_environment_value: bool = false,
};

fn recordSetTunnel(
    ref: ?*anyopaque,
    _: [*c]const u8,
    info_json: [*c]const u8,
) callconv(.c) c.pp_tun {
    const recorder: *TunnelCommitRecorder = @ptrCast(@alignCast(ref orelse return null));
    if (info_json == null) return null;
    const json = std.mem.span(info_json);
    recorder.calls += 1;
    recorder.received_settings_only_info = std.mem.indexOf(
        u8,
        json,
        "\"requiresVirtualDevice\":false",
    ) != null;
    return null;
}

fn recordEnvironmentValue(
    ref: ?*anyopaque,
    key: [*c]const u8,
    value: [*c]const u8,
) callconv(.c) void {
    const recorder: *TunnelCommitRecorder = @ptrCast(@alignCast(ref orelse return));
    if (key == null) return;
    recorder.received_environment_key = std.mem.eql(u8, std.mem.span(key), "test.key");
    if (value != null) {
        recorder.environment_set_calls += 1;
        recorder.received_environment_value = std.mem.eql(
            u8,
            std.mem.span(value),
            "{\"enabled\":true}",
        );
    } else {
        recorder.environment_remove_calls += 1;
    }
}

fn platformOptions(recorder: *TunnelCommitRecorder) Platform.Options {
    var functions = c.pp_tun_ctrl_fnt_current();
    functions.set_tunnel = recordSetTunnel;
    functions.set_environment_value = recordEnvironmentValue;
    return .{ .ref = recorder, .fnt = functions };
}

test "platform commits settings when no virtual device is required" {
    var recorder = TunnelCommitRecorder{};
    var platform = try Platform.init(platformOptions(&recorder));
    defer platform.deinit();

    const tun = try platform.tunnelController().setTunnelSettings(.{});

    try std.testing.expect(tun == null);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(recorder.received_settings_only_info);
}

test "platform forwards environment values and removals" {
    var recorder = TunnelCommitRecorder{};
    var platform = try Platform.init(platformOptions(&recorder));
    defer platform.deinit();

    const controller = platform.tunnelController();
    controller.setEnvironmentValue("test.key", "{\"enabled\":true}");
    controller.setEnvironmentValue("test.key", null);

    try std.testing.expectEqual(@as(usize, 1), recorder.environment_set_calls);
    try std.testing.expectEqual(@as(usize, 1), recorder.environment_remove_calls);
    try std.testing.expect(recorder.received_environment_key);
    try std.testing.expect(recorder.received_environment_value);
}

test "platform socket factory returns current reachability" {
    var platform = try Platform.init(.{});
    defer platform.deinit();

    try std.testing.expect(platform.socketFactory().currentReachability() == null);

    platform_source.testing.notifyReachability(&platform, reachable(true));

    const info = platform.socketFactory().currentReachability() orelse return error.TestUnexpectedResult;
    try std.testing.expect(info.reachable);
}

test "platform network monitor receives reachability changes" {
    const Recorder = struct {
        calls: usize = 0,
        last_reachable: bool = false,

        fn notifyReachability(ptr: ?*anyopaque, reachability: ReachabilityInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.calls += 1;
            self.last_reachable = reachability.reachable;
        }

        fn notifyBetterPath(_: ?*anyopaque) void {}
    };

    var platform = try Platform.init(.{});
    defer platform.deinit();
    var recorder = Recorder{};
    const monitor = platform.networkMonitor();

    try std.testing.expect(!monitor.isReachable());
    monitor.setEventHandler(.{
        .ptr = &recorder,
        .on_reachability = Recorder.notifyReachability,
        .on_better_path = Recorder.notifyBetterPath,
    });

    platform_source.testing.notifyReachability(&platform, reachable(true));
    try std.testing.expect(monitor.isReachable());
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(recorder.last_reachable);

    monitor.setEventHandler(null);
    platform_source.testing.notifyReachability(&platform, reachable(false));
    try std.testing.expect(!monitor.isReachable());
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "platform builds socket wrapper options" {
    var platform = try Platform.init(.{
        .socket_buf_size = 4096,
    });
    defer platform.deinit();

    const endpoint = api.ExtendedEndpoint.init(
        "127.0.0.1",
        api.EndpointProtocol.init(.udp, 1194),
    ) orelse return error.TestUnexpectedResult;

    const options = socketOptions(&platform, endpoint, reachable(true), 5000);
    try std.testing.expectEqualStrings("127.0.0.1", options.endpoint.address);
    try std.testing.expectEqual(api.EndpointProtocol{
        .socket_type = .udp,
        .port = 1194,
    }, options.endpoint.proto);
    try std.testing.expectEqual(@as(c_int, 5000), options.timeout_ms);
    try std.testing.expectEqual(@as(c_int, 4096), options.buf_size);
    try std.testing.expect(options.reachability.?.reachable);
    try std.testing.expect(options.configure != null);
    try std.testing.expectEqual(@intFromPtr(&platform), @intFromPtr(options.configure_ctx.?));
}

test "platform configure socket allows missing context" {
    try std.testing.expect(platformConfigureSocket(null, @as(SocketDescriptor, 42), null));
}

test "platform records better path notifications" {
    const Recorder = struct {
        calls: usize = 0,

        fn onReachability(_: ?*anyopaque, _: ReachabilityInfo) void {}

        fn onBetterPath(ptr: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.calls += 1;
        }
    };

    var recorder = Recorder{};
    var platform = try Platform.init(.{});
    defer platform.deinit();
    const monitor = platform.networkMonitor();
    monitor.setEventHandler(.{
        .ptr = &recorder,
        .on_reachability = Recorder.onReachability,
        .on_better_path = Recorder.onBetterPath,
    });

    platform_source.testing.notifyBetterPath(&platform);

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(usize, 1), platform_source.testing.betterPathCount(&platform));

    monitor.setEventHandler(null);
    platform_source.testing.notifyBetterPath(&platform);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(usize, 2), platform_source.testing.betterPathCount(&platform));
}
