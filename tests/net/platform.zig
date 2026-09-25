// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const io = @import("source").net_io;
const platform_source = @import("source").net_platform;
const io_c = @import("source").ffi.io;

const Platform = platform_source.Platform;
const ReachabilityInfo = io.ReachabilityInfo;
const SocketDescriptor = io.SocketDescriptor;

const api = core.api;
const platformConfigureSocket = platform_source.testing.platformConfigureSocket;
const reachable = io.testing.reachable;
const socketOptions = platform_source.testing.socketOptions;

const TunnelCommitRecorder = struct {
    calls: usize = 0,
    received_module_id: bool = false,
    environment_set_calls: usize = 0,
    environment_remove_calls: usize = 0,
    received_environment_key: bool = false,
    received_environment_value: bool = false,
};

fn recordSetTunnel(
    ref: ?*anyopaque,
    _: [*c]const u8,
    info_json: [*c]const u8,
) callconv(.c) io_c.pp_tun {
    const recorder: *TunnelCommitRecorder = @ptrCast(@alignCast(ref orelse return null));
    if (info_json == null) return null;
    const json = std.mem.span(info_json);
    recorder.calls += 1;
    recorder.received_module_id = std.mem.indexOf(
        u8,
        json,
        "\"originalModuleId\":\"11111111-1111-4111-8111-111111111111\"",
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
    var functions = io_c.pp_tun_ctrl_fnt_current();
    functions.set_tunnel = recordSetTunnel;
    functions.set_environment_value = recordEnvironmentValue;
    return .{ .ref = recorder, .fnt = functions };
}

test "platform reports unavailable tunnel after committing settings" {
    var recorder = TunnelCommitRecorder{};
    var platform = try Platform.init(platformOptions(&recorder));
    defer platform.deinit();

    try std.testing.expectError(
        error.TunNotAvailable,
        platform.tunnelController().setTunnelSettings(.{
            .original_module_id = "11111111-1111-4111-8111-111111111111".*,
        }),
    );

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(recorder.received_module_id);
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

test "platform builds POSIX socket wrapper options" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
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

test "settings-only daemons release owned TUN descriptors" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const source = @import("source");
    const mock = source.mock;
    const libc = struct {
        extern "c" fn close(fd: c_int) c_int;
    };
    // Match portable TUN storage on POSIX. A pipe exercises ownership without
    // requiring privileges to create a real TUN device. Android uses only fd.
    const NativeTun = extern struct {
        fd: c_int,
        dev_name: ?[*:0]const u8 = null,
    };
    const Controller = struct {
        mock: mock.MockTunnelController = .{},
        native: *NativeTun,
        handed_out: bool = false,

        fn setTunnel(raw: ?*anyopaque, _: api.TunnelRemoteInfoWrapper) source.net.TunnelController.Error!io.TunWrapper {
            const base: *mock.MockTunnelController = @ptrCast(@alignCast(raw.?));
            const self: *@This() = @fieldParentPtr("mock", base);
            self.handed_out = true;
            return io.TunWrapper.init(@ptrCast(self.native));
        }
    };
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator, mock.dnsOnlyProfileJson());
    defer profile.deinit(allocator);
    var registry = try source.net.ConnectionRegistry.init(allocator, &.{});
    defer registry.deinit(allocator);
    inline for (.{ source.net_daemon.Daemon, source.net_daemon_v2.Daemon }) |Daemon| {
        var fds: [2]c_int = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        defer _ = libc.close(fds[1]);
        var read_fd_open = true;
        defer if (read_fd_open) {
            _ = libc.close(fds[0]);
        };
        const native = try std.heap.c_allocator.create(NativeTun);
        native.* = .{ .fd = fds[0] };
        var controller = Controller{ .native = native };
        defer if (!controller.handed_out) {
            std.heap.c_allocator.destroy(native);
        };
        var vtable = controller.mock.interface().vtable.*;
        vtable.set_tunnel_settings = Controller.setTunnel;
        var monitor = mock.MockNetworkMonitor{};
        const sut = try Daemon.create(allocator, &profile, .{
            .objects = .{
                .registry = &registry,
                .controller = .{ .ptr = &controller.mock, .vtable = &vtable },
                .resolver = mock.noopDNSResolver(),
                .factory = mock.noopSocketFactory(),
                .monitor = monitor.interface(),
            },
            .options = .{},
        });
        defer sut.destroy();
        try sut.start();
        defer sut.stop();
        try std.testing.expect(controller.handed_out);
        read_fd_open = std.c.fcntl(fds[0], std.c.F.GETFD) != -1;
        if (comptime builtin.abi.isAndroid()) {
            // The service retains ownership of the original Android fd.
            try std.testing.expect(read_fd_open);
        } else {
            // Free the leaked allocation if this regression is reintroduced.
            if (read_fd_open) std.heap.c_allocator.destroy(native);
            try std.testing.expect(!read_fd_open);
        }
    }
}

test "platform cancellation formats extended errors only at the C boundary" {
    const Recorder = struct {
        buffer: [128]u8 = undefined,
        len: ?usize = null,
        calls: usize = 0,

        fn cancel(ctx: ?*anyopaque, code: [*c]const u8) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.len = null;
            if (code != null) {
                const raw = std.mem.span(code);
                @memcpy(self.buffer[0..raw.len], raw);
                self.len = raw.len;
            }
        }
    };
    var recorder = Recorder{};
    var functions = io_c.pp_tun_ctrl_fnt_current();
    functions.cancel_tunnel = Recorder.cancel;
    var platform = try Platform.init(.{ .ref = &recorder, .fnt = functions });
    defer platform.deinit();
    const controller = platform.tunnelController();

    controller.cancelTunnelConnection(api.openVPNErrorCode(.tlsFailure));
    try std.testing.expectEqualStrings("openVPN.tlsFailure", recorder.buffer[0..recorder.len.?]);
    controller.cancelTunnelConnection(.{ .code = .authentication });
    try std.testing.expectEqualStrings("authentication", recorder.buffer[0..recorder.len.?]);
    controller.cancelTunnelConnection(null);
    try std.testing.expect(recorder.len == null);
    try std.testing.expectEqual(@as(usize, 3), recorder.calls);
}
