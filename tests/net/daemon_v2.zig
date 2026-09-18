// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const daemon = @import("source").net_daemon_v2;
const daemon_helpers = @import("source").net_daemon_helpers;
const net = @import("source").net;
const Looper = net.Looper;
const mock_mod = @import("source").mock;

const api = core.api;

const Daemon = daemon.Daemon;
const ConnectionGate = daemon_helpers.ConnectionGate;

test "v2 daemon resets terminal status before retrying failed replacement link" {
    const Factory = struct {
        const endpoint_list = [_]api.ExtendedEndpoint{
            api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?,
        };

        fn endpoints(_: *anyopaque) []const api.ExtendedEndpoint {
            return &endpoint_list;
        }

        fn create(
            ptr: ?*anyopaque,
            _: std.mem.Allocator,
            _: net.ConnectionModule,
            _: net.Sandbox,
        ) net.ConnectionCreateError!net.Connection {
            return .{ .ptr = ptr.?, .vtable = &vtable };
        }

        const vtable = blk: {
            var value = FailingStartConnection.vtable;
            value.endpoints = endpoints;
            break :blk value;
        };
        const implementation_vtable = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const allocator = std.testing.allocator;
    for ([_]api.ConnectionStatus{ .connected, .connecting }) |previous_status| {
        const cancels = previous_status == .connected;
        var connection = FailingStartConnection{};
        var registry = try net.ConnectionRegistry.init(allocator, &.{.{
            .ptr = &connection,
            .vtable = &Factory.implementation_vtable,
        }});
        defer registry.deinit(allocator);
        var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
        defer profile.deinit(allocator);
        var controller = mock_mod.MockTunnelController{};
        var monitor = mock_mod.MockNetworkMonitor{};
        const sut = try Daemon.create(allocator, &profile, .{
            .objects = .{
                .registry = &registry,
                .controller = controller.interface(),
                .resolver = mock_mod.noopDNSResolver(),
                .factory = mock_mod.noopSocketFactory(),
                .monitor = monitor.interface(),
            },
            .options = .{ .reconnection_delay_ms = 60_000, .cancels_unrecoverable = cancels },
        });
        defer sut.destroy();
        const connection_daemon = sut.implementation.connection;
        try sut.start();
        defer sut.stop();
        connection_daemon.resume_gate_timer.cancel();
        connection_daemon.resume_gate_timer.wait();
        try std.testing.expectError(error.AlreadyStarted, sut.start());
        // The mock has no event producers and the retry timer is drained.
        // Seed the pre-termination state without a legacy status callback.
        sut.snapshot_publisher.setConnectionStatus(previous_status);
        _ = connection_daemon.gate.updateStatus(previous_status);
        controller.reasserting = previous_status == .connecting;

        _ = try controller.interface().setTunnelSettings(.{
            .profile = profile,
            .original_module_id = @import("source").net_connection.activeConnectionModule(&profile).?.id(),
            .requires_virtual_device = false,
        });
        try std.testing.expect(controller.last_settings != null);
        const cleared_before = controller.clear_tunnel_settings_count;
        try connection_daemon.looper.stop();
        // Drain the termination notification and its queued recovery barrier.
        try std.testing.expectError(error.AlreadyStarted, sut.start());
        try std.testing.expectError(error.AlreadyStarted, sut.start());
        try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
        try std.testing.expect(!controller.reasserting);
        try std.testing.expectEqual(cleared_before + 1, controller.clear_tunnel_settings_count);
        try std.testing.expect(controller.last_settings == null);

        // The replacement's factory rejected the link. Resuming the gate
        // must attempt setup again and report another failure snapshot.
        const snapshots = controller.report_snapshot_count;
        try connection_daemon.actor.perform(.resumeGate);
        try std.testing.expect(controller.report_snapshot_count > snapshots);
        try std.testing.expectEqual(@as(usize, 0), controller.cancel_count);

        // A terminal protocol failure uses the shared Daemon state to pause
        // connection retries, even when host cancellation is disabled.
        try connection_daemon.actor.perform(.{ .onConnectionFailed = .{
            .code = .authentication,
            .disposition = .cancel,
        } });
        try std.testing.expect(sut.state == .failed);
        try std.testing.expect(!connection_daemon.gate.isReady());
        try std.testing.expectEqual(@as(usize, if (cancels) 1 else 0), controller.cancel_count);
        const failed_snapshots = controller.report_snapshot_count;
        try connection_daemon.actor.perform(.resumeGate);
        try std.testing.expectEqual(failed_snapshots, controller.report_snapshot_count);
        sut.hold();
        try std.testing.expect(sut.state == .stopped);
        try std.testing.expectEqualStrings("authentication", sut.snapshot_publisher.environment.last_error_code.?);
    }
}

test "v2 daemon dispatches controls to looper and owns queued establishment metadata" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const source = @import("source");
    const libc = struct {
        extern "c" fn close(fd: std.c.fd_t) c_int;
    };
    const Probe = struct {
        looper: *Looper,
        profile: *const api.Profile,
        reachability_count: usize = 0,
        stop_count: usize = 0,
        shutdown_count: usize = 0,
        detach_count: usize = 0,
        exit_write_count: usize = 0,
        destroyed: bool = false,

        fn start(_: *anyopaque, _: net.Connection.Events) net.ConnectionStartError!bool {
            return false;
        }
        fn shutdown(raw: *anyopaque, reason: net.Connection.ShutdownReason) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.looper.isOnQueue());
            self.shutdown_count += 1;
            switch (self.shutdown_count) {
                1, 2 => std.debug.assert(reason == .failure and reason.failure == .reconnect),
                else => std.debug.assert(reason == .explicit_stop),
            }
            if (self.shutdown_count == 2) {
                std.debug.assert(self.looper.isLinkAttached() and self.looper.isTunAttached());
                self.looper.writeOutOfBand(&.{"exit"}, .link) catch unreachable;
            }
        }
        fn setMask(_: *anyopaque, _: bool, _: bool) source.net_io.Error!void {}
        fn reset(_: *anyopaque) source.net_io.Error!void {}
        fn read(_: *anyopaque, _: []u8) source.net_io.Error!?usize {
            return null;
        }
        fn write(raw: *anyopaque, bytes: []const u8, offset: usize) source.net_io.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.shutdown_count == 2 and self.detach_count == 0);
            self.exit_write_count += 1;
            return bytes.len - offset;
        }
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.shutdown_count == 2 and self.stop_count == 1);
            self.detach_count += 1;
        }
        fn lastError(_: *anyopaque) c_int {
            return 0;
        }
        const io_vtable = source.net_io.IOInterface.VTable{
            .set_event_mask = setMask,
            .reset_events = reset,
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .last_error_code = lastError,
        };
        fn stop(raw: *anyopaque, _: u32, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.looper.isOnQueue());
            std.debug.assert(self.shutdown_count == self.stop_count + 1);
            std.debug.assert(!self.looper.isLinkAttached() and !self.looper.isTunAttached());
            self.stop_count += 1;
            sink.stopped(sink.ctx);
        }
        fn reachability(raw: *anyopaque, _: net.ReachabilityInfo, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.looper.isOnQueue());
            self.reachability_count += 1;
            sink.data_count(sink.ctx, .{});
        }
        fn betterPath(raw: *anyopaque, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.looper.isOnQueue());
            var servers = [_]api.Address{api.Address.parseRaw("1.1.1.1").?};
            const modules = [_]api.TaggedModule{.{ .DNS = .{
                .id = "11111111-1111-4111-8111-111111111111".*,
                .servers = &servers,
            } }};
            sink.established(sink.ctx, .{
                .remote_endpoint = api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?,
                .info = .{
                    .profile = self.profile.*,
                    .original_module_id = "11111111-1111-4111-8111-111111111111".*,
                    .requires_virtual_device = true,
                    .modules = &modules,
                },
            });
            // This storage expires before the actor can process established.
            servers[0] = api.Address.parseRaw("9.9.9.9").?;
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(!self.looper.isOnQueue());
            self.destroyed = true;
        }
        fn finish(_: ?*anyopaque, _: ?Looper.Failure) void {}
        const vtable = net.Connection.VTable{
            .start = start,
            .shutdown = shutdown,
            .stop = stop,
            .network_change = reachability,
            .better_path = betterPath,
            .destroy = destroy,
        };
    };
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
    defer profile.deinit(allocator);
    var registry = try net.ConnectionRegistry.init(allocator, &.{});
    defer registry.deinit(allocator);
    var controller = mock_mod.MockTunnelController{};
    var controller_vtable = controller.interface().vtable.*;
    // Retain the recorded payload after the deliberately failed setup.
    controller_vtable.clear_tunnel_settings = struct {
        fn call(_: ?*anyopaque, _: bool) void {}
    }.call;
    var monitor = mock_mod.MockNetworkMonitor{};
    const sut = try Daemon.create(allocator, &profile, .{
        .objects = .{
            .registry = &registry,
            .controller = .{ .ptr = &controller, .vtable = &controller_vtable },
            .resolver = mock_mod.noopDNSResolver(),
            .factory = mock_mod.noopSocketFactory(),
            .monitor = monitor.interface(),
        },
        .options = .{ .reconnection_delay_ms = 60_000 },
    });
    defer sut.destroy();
    const connection_daemon = sut.implementation.connection;
    const looper = try allocator.create(Looper);
    looper.* = try Looper.init(allocator, .{ .on_finish = .{ .callback = Probe.finish } });
    var probe = Probe{ .looper = looper, .profile = &sut.profile };
    const endpoints = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
    // Publish a runtime before any actor/looper work, without opening sockets.
    connection_daemon.connection = .{ .ptr = &probe, .vtable = &Probe.vtable };
    connection_daemon.endpoint_resolver = net.EndpointResolver.init(allocator, &endpoints);
    connection_daemon.looper = looper;
    sut.state = .started;
    sut.snapshot_publisher.setConnectionStatus(.connecting);
    try looper.start();
    defer sut.stop();

    // The factory rejects the link. The delayed callback must reenable the
    // gate even though no connection session ever started or emitted events.
    connection_daemon.gate.setReachabilityBlock(reachabilityBlock(&monitor));
    _ = connection_daemon.gate.setEnabled(true);
    sut.options.reconnection_delay_ms = 10;
    try connection_daemon.actor.perform(.evaluateConnection);
    connection_daemon.resume_gate_timer.wait();
    try std.testing.expect(connection_daemon.gate.isReady());
    try std.testing.expectEqual(@as(usize, 0), probe.stop_count);
    sut.options.reconnection_delay_ms = 60_000;

    try connection_daemon.actor.perform(.{ .onReachability = .{ .reachable = false } });
    try connection_daemon.actor.perform(.onBetterPath);
    try connection_daemon.actor.perform(.resumeGate); // Drain establishment and setup failure.
    try std.testing.expectEqual(@as(usize, 1), probe.reachability_count);
    try std.testing.expectEqual(@as(usize, 1), controller.set_tunnel_settings_count);
    try std.testing.expectEqualStrings("1.1.1.1", controller.last_settings.?.dnsServer(0));
    // The null mock TUN makes establishment fail; stopping it also runs on looper.
    try std.testing.expectEqual(@as(usize, 1), probe.stop_count);
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SkipZigTest;
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    const native_io = source.net_io.IOInterface{ .ptr = &probe, .vtable = &Probe.io_vtable };
    try looper.attach(.{ .pair = .{ .link = .{ .fd = fds[0], .io = native_io } } });
    try looper.attach(.{ .pair = .{ .tun = .{ .fd = fds[1], .io = native_io } } });
    // A protocol failure must finalize the attempt just like setup failure:
    // shutdown while attached, detach both sides, then stop on the looper.
    try connection_daemon.actor.perform(.{ .onConnectionFailed = .{
        .code = .ioFailure,
        .disposition = .reconnect,
    } });
    try connection_daemon.actor.perform(.resumeGate); // Drain the queued stopped event.
    try std.testing.expectEqual(@as(usize, 2), probe.shutdown_count);
    try std.testing.expectEqual(@as(usize, 2), probe.detach_count);
    try std.testing.expectEqual(@as(usize, 1), probe.exit_write_count);
    try std.testing.expectEqual(@as(usize, 2), probe.stop_count);
    try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expect(!probe.destroyed);
    sut.stop();
    try std.testing.expectEqual(@as(usize, 3), probe.stop_count);
    try std.testing.expect(probe.destroyed);
}

test "v2 daemon preserves settings-only failure and hold behavior" {
    const Recorder = struct {
        caller_thread: std.Thread.Id,
        callbacks_on_caller: bool = true,
        last_error: ?api.PartoutErrorCode = null,
        fn status(_: *anyopaque, _: api.ConnectionStatus) void {}
        fn dataCount(_: *anyopaque, _: api.DataCount) void {}
        fn lastError(ctx: *anyopaque, code: api.PartoutErrorCode) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.callbacks_on_caller = self.callbacks_on_caller and std.Thread.getCurrentId() == self.caller_thread;
            self.last_error = code;
        }
        fn remove(ctx: *anyopaque, key: daemon.EventKey) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.callbacks_on_caller = self.callbacks_on_caller and std.Thread.getCurrentId() == self.caller_thread;
            if (key == .last_error_code) self.last_error = null;
        }
        fn failSettings(_: ?*anyopaque, _: api.TunnelRemoteInfoWrapper) net.TunnelController.Error!?net.TunWrapper {
            return error.TunNotAvailable;
        }
    };
    const allocator = std.testing.allocator;
    var registry = try net.ConnectionRegistry.init(allocator, &.{});
    defer registry.deinit(allocator);
    for ([_]bool{ false, true }) |fails| {
        for ([_]bool{ false, true }) |hold| {
            for ([_]bool{ false, true }) |cancels| {
                var controller = mock_mod.MockTunnelController{};
                var vtable = controller.interface().vtable.*;
                if (fails) vtable.set_tunnel_settings = Recorder.failSettings;
                var monitor = mock_mod.MockNetworkMonitor{};
                var recorder = Recorder{ .caller_thread = std.Thread.getCurrentId() };
                const sut = blk: {
                    var profile = try api.Profile.parse(allocator, mock_mod.dnsOnlyProfileJson());
                    defer profile.deinit(allocator);
                    break :blk try Daemon.create(allocator, &profile, .{
                        .objects = .{
                            .registry = &registry,
                            .controller = .{ .ptr = &controller, .vtable = &vtable },
                            .resolver = mock_mod.noopDNSResolver(),
                            .factory = mock_mod.noopSocketFactory(),
                            .monitor = monitor.interface(),
                        },
                        .options = .{
                            .cancels_unrecoverable = cancels,
                            .events = .{ .ctx = &recorder, .status = Recorder.status, .last_error = Recorder.lastError, .data_count = Recorder.dataCount, .remove_key = Recorder.remove },
                        },
                    });
                };
                defer sut.destroy();
                try std.testing.expect(sut.isSettingsOnly());
                try sut.start();
                defer sut.stop();
                try std.testing.expectError(error.AlreadyStarted, sut.start());
                try std.testing.expectEqual(@as(usize, 0), monitor.start_count);
                try std.testing.expectEqual(@as(usize, 0), sut.testStatuses().len);
                try std.testing.expectEqual(@as(usize, if (fails and cancels) 1 else 0), controller.cancel_count);
                if (fails) {
                    try std.testing.expectEqual(api.PartoutErrorCode.tunNotAvailable, recorder.last_error.?);
                    try std.testing.expect(!controller.reasserting);
                } else {
                    try std.testing.expectEqual(@as(usize, 1), controller.last_settings.?.profile_module_count);
                    try std.testing.expect(!controller.last_settings.?.requires_virtual_device);
                }
                if (hold) sut.hold() else sut.stop();
                try std.testing.expectEqual(@as(usize, 1), controller.clear_tunnel_settings_count);
                try std.testing.expectEqual(@as(?api.PartoutErrorCode, if (fails and hold) .tunNotAvailable else null), recorder.last_error);
                sut.stop();
                try std.testing.expectEqual(@as(usize, 1), controller.clear_tunnel_settings_count);
                try std.testing.expect(recorder.callbacks_on_caller);
            }
        }
    }
}

test "v2 settings daemon creation rolls back allocation failures" {
    const Fixture = struct {
        fn create(allocator: std.mem.Allocator, profile: *const api.Profile, registry: *const net.ConnectionRegistry) !void {
            var controller = mock_mod.MockTunnelController{};
            var monitor = mock_mod.MockNetworkMonitor{};
            const sut = try Daemon.create(allocator, profile, .{
                .objects = .{
                    .registry = registry,
                    .controller = controller.interface(),
                    .resolver = mock_mod.noopDNSResolver(),
                    .factory = mock_mod.noopSocketFactory(),
                    .monitor = monitor.interface(),
                },
                .options = .{},
            });
            defer sut.destroy();
            try std.testing.expect(sut.isSettingsOnly());
        }
    };
    const allocator = std.testing.allocator;
    var profile = try api.Profile.parse(allocator, mock_mod.dnsOnlyProfileJson());
    defer profile.deinit(allocator);
    var registry = try net.ConnectionRegistry.init(allocator, &.{});
    defer registry.deinit(allocator);
    try std.testing.checkAllAllocationFailures(allocator, Fixture.create, .{ &profile, &registry });
}

test "v2 daemon owns the profile and rolls back connection startup allocations" {
    const Factory = struct {
        destroy_count: usize = 0,
        profile: ?*const api.Profile = null,
        const endpoint_list = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
        fn endpoints(_: *anyopaque) []const api.ExtendedEndpoint {
            return &endpoint_list;
        }
        fn create(ptr: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.profile = sb.profile;
            return .{ .ptr = self, .vtable = &vtable };
        }
        fn destroy(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroy_count += 1;
        }
        const vtable = blk: {
            var value = FailingStartConnection.vtable;
            value.endpoints = endpoints;
            value.destroy = destroy;
            break :blk value;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const allocator = std.testing.allocator;
    var offset: usize = 0;
    while (offset < 32) : (offset += 1) {
        var factory = Factory{};
        var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &factory, .vtable = &Factory.implementation }});
        defer registry.deinit(allocator);
        var controller = mock_mod.MockTunnelController{};
        var monitor = mock_mod.MockNetworkMonitor{ .reachable = false };
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        const sut = blk: {
            var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
            defer profile.deinit(allocator);
            break :blk try Daemon.create(failing.allocator(), &profile, .{
                .objects = .{
                    .registry = &registry,
                    .controller = controller.interface(),
                    .resolver = mock_mod.noopDNSResolver(),
                    .factory = mock_mod.noopSocketFactory(),
                    .monitor = monitor.interface(),
                },
                .options = .{},
            });
        };
        defer sut.destroy();
        try std.testing.expect(sut.isConnectionProfile());
        // Fail each allocation in ConnectionDaemon startup, including the
        // looper's. The caller's original profile has already been released.
        failing.fail_index = failing.alloc_index + offset;
        sut.start() catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), factory.destroy_count);
            try std.testing.expectEqual(@as(usize, 0), monitor.start_count);
            // Failed startup remains retryable and retains profile ownership.
            try sut.start();
            defer sut.stop();
            try std.testing.expectEqual(&sut.profile, factory.profile.?);
            sut.stop();
            try std.testing.expectEqual(@as(usize, 2), factory.destroy_count);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        defer sut.stop();
        try std.testing.expectEqual(&sut.profile, factory.profile.?);
        try std.testing.expectEqualSlices(api.ConnectionStatus, &.{.disconnected}, sut.testStatuses());
        sut.hold();
        try std.testing.expectEqual(@as(usize, 1), factory.destroy_count);
        try std.testing.expect(monitor.event_handler == null);
        try std.testing.expectEqualSlices(api.ConnectionStatus, &.{ .disconnected, .disconnecting, .disconnected }, sut.testStatuses());
        sut.stop();
        try std.testing.expectEqual(@as(usize, 1), factory.destroy_count);
        return;
    }
    return error.TestUnexpectedResult;
}

const FailingStartConnection = struct {
    start_count: usize = 0,

    fn implementation(self: *FailingStartConnection) net.ConnectionImplementation {
        return .{
            .ptr = self,
            .vtable = &implementation_vtable,
        };
    }

    fn moduleType(_: ?*anyopaque) api.ModuleType {
        return .OpenVPN;
    }

    fn create(
        ptr: ?*anyopaque,
        _: std.mem.Allocator,
        _: net.ConnectionModule,
        _: net.Sandbox,
    ) net.ConnectionCreateError!net.Connection {
        const self: *FailingStartConnection = @ptrCast(@alignCast(ptr.?));
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn start(ptr: *anyopaque, events: net.Connection.Events) net.ConnectionStartError!bool {
        const self: *FailingStartConnection = @ptrCast(@alignCast(ptr));
        self.start_count += 1;
        events.status(events.ctx, .connecting);
        events.status(events.ctx, .disconnected);
        return error.UnableToStart;
    }

    fn stop(_: *anyopaque, _: u32, _: net.Connection.Events) void {}

    fn networkChange(_: *anyopaque, _: net.ReachabilityInfo, _: net.Connection.Events) void {}

    fn betterPath(_: *anyopaque, _: net.Connection.Events) void {}

    fn destroy(_: *anyopaque) void {}

    const vtable = net.Connection.VTable{
        .start = start,
        .stop = stop,
        .network_change = networkChange,
        .better_path = betterPath,
        .destroy = destroy,
    };

    const implementation_vtable = net.ConnectionImplementation.VTable{
        .module_type = moduleType,
        .create_connection = create,
    };
};

fn reachabilityBlock(monitor: *const mock_mod.MockNetworkMonitor) ConnectionGate.ReachabilityBlock {
    return .{
        .ptr = monitor,
        .is_reachable = mockIsReachable,
    };
}

fn mockIsReachable(ptr: ?*const anyopaque) bool {
    const monitor: *const mock_mod.MockNetworkMonitor = @ptrCast(@alignCast(ptr.?));
    return monitor.reachable;
}

test "v2 daemon owns environment updates and delivers finalization clears on actor" {
    const Factory = struct {
        events: ?net.Connection.Events = null,
        producer_thread: ?std.Thread.Id = null,

        fn create(raw: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.events = sb.events;
            return .{ .ptr = self, .vtable = &vtable };
        }
        fn betterPath(raw: *anyopaque, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.producer_thread = std.Thread.getCurrentId();
            var key = "OpenVPN.serverConfiguration".*;
            var value = "{\"test\":true}".*;
            // The actor is waiting for this looper operation to return, so it
            // cannot consume the borrowed strings before we overwrite them.
            sink.set_env(sink.ctx, &key, &value);
            @memset(&key, 'x');
            @memset(&value, 'x');
        }
        fn stop(_: *anyopaque, _: u32, sink: net.Connection.Events) void {
            sink.set_env(sink.ctx, "OpenVPN.serverConfiguration", null);
            sink.stopped(sink.ctx);
        }
        const endpoint_list = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
        fn endpoints(_: *anyopaque) []const api.ExtendedEndpoint {
            return &endpoint_list;
        }
        const vtable = blk: {
            var value = FailingStartConnection.vtable;
            value.endpoints = endpoints;
            value.better_path = betterPath;
            value.stop = stop;
            break :blk value;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const Controller = struct {
        mock: mock_mod.MockTunnelController = .{},
        updates: usize = 0,
        clears: usize = 0,
        delivery_thread: ?std.Thread.Id = null,
        valid_payload: bool = true,

        fn setEnvironment(raw: ?*anyopaque, key: []const u8, value: ?[]const u8) void {
            const mock: *mock_mod.MockTunnelController = @ptrCast(@alignCast(raw.?));
            const self: *@This() = @fieldParentPtr("mock", mock);
            const current = std.Thread.getCurrentId();
            if (self.delivery_thread) |previous| std.debug.assert(previous == current);
            self.delivery_thread = current;
            self.valid_payload = self.valid_payload and std.mem.eql(u8, key, "OpenVPN.serverConfiguration");
            if (value) |bytes| {
                self.updates += 1;
                self.valid_payload = self.valid_payload and std.mem.eql(u8, bytes, "{\"test\":true}");
            } else {
                self.clears += 1;
            }
        }
    };
    const allocator = std.testing.allocator;
    var factory = Factory{};
    var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &factory, .vtable = &Factory.implementation }});
    defer registry.deinit(allocator);
    var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
    defer profile.deinit(allocator);
    var controller = Controller{};
    var vtable = controller.mock.interface().vtable.*;
    vtable.set_environment_value = Controller.setEnvironment;
    var monitor = mock_mod.MockNetworkMonitor{ .reachable = false };
    const sut = try Daemon.create(allocator, &profile, .{
        .objects = .{
            .registry = &registry,
            .controller = .{ .ptr = &controller.mock, .vtable = &vtable },
            .resolver = mock_mod.noopDNSResolver(),
            .factory = mock_mod.noopSocketFactory(),
            .monitor = monitor.interface(),
        },
        .options = .{},
    });
    defer sut.destroy();
    try sut.start();
    defer sut.stop();
    const actor = sut.implementation.connection.actor;
    try actor.perform(.onBetterPath);
    try actor.perform(.resumeGate);
    try std.testing.expectEqual(@as(usize, 1), controller.updates);
    try std.testing.expect(controller.valid_payload);
    try std.testing.expect(controller.delivery_thread.? != factory.producer_thread.?);
    try std.testing.expect(controller.delivery_thread.? != std.Thread.getCurrentId());

    sut.stop();
    try actor.perform(.resumeGate);
    try std.testing.expectEqual(@as(usize, 1), controller.clears);
    // A late update must not recreate environment state after shutdown.
    const sink = factory.events.?;
    sink.set_env(sink.ctx, "OpenVPN.serverConfiguration", "stale");
    try actor.perform(.resumeGate);
    try std.testing.expectEqual(@as(usize, 1), controller.updates);
    try std.testing.expect(controller.valid_payload);
}
