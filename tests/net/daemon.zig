// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const source = @import("source");
const builtin = @import("builtin");
const io = source.net_io;

const core = source.core;
const daemon = source.net_daemon;
const daemon_helpers = source.net_daemon_helpers;
const ConnectionWorker = source.net_connection_worker.ConnectionWorker;
const net = source.net;
const Looper = source.net_looper.Looper;
const mock_mod = source.mock;

const api = core.api;

const Daemon = daemon.Daemon;
const ConnectionGate = daemon_helpers.ConnectionGate;

test "daemon terminates and cancels after terminal looper failure" {
    // Windows I/O polling is not implemented yet.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Factory = struct {
        const endpoint_list = [_]api.ExtendedEndpoint{
            api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?,
        };

        fn endpoints(_: *anyopaque) ?[]const api.ExtendedEndpoint {
            return &endpoint_list;
        }

        fn create(
            ptr: ?*anyopaque,
            _: std.mem.Allocator,
            _: net.ConnectionModule,
            _: net.Sandbox,
        ) net.ConnectionCreateError!net.Connection {
            return .{ .ptr = ptr.?, .vtable = &vtable, .daemon_io = .none };
        }

        fn terminate(raw: *anyopaque, _: net.Connection.Events) void {
            const connection: *FailingStartConnection = @ptrCast(@alignCast(raw));
            const owner = connection.terminal_daemon.?.implementation.connection;
            std.debug.assert(daemon.testing.isCurrentThread(owner));
            owner.looper.stop() catch unreachable;
        }

        const vtable = blk: {
            var value = FailingStartConnection.vtable;
            value.endpoints = endpoints;
            value.better_path = terminate;
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
        var event_recorder = mock_mod.DaemonEventRecorder{};
        var monitor = mock_mod.MockNetworkMonitor{};
        const sut = try Daemon.create(allocator, &profile, .{
            .objects = .{
                .registry = &registry,
                .controller = controller.interface(),
                .resolver = mock_mod.noopDNSResolver(),
                .factory = mock_mod.noopSocketFactory(),
                .monitor = monitor.interface(),
            },
            .options = .{ .events = event_recorder.events(), .reconnection_delay_ms = 60_000, .cancels_unrecoverable = cancels },
        });
        defer sut.destroy();
        const connection_daemon = sut.implementation.connection;
        connection.terminal_daemon = sut;
        try sut.start();
        defer sut.stop();
        try std.testing.expect(@TypeOf(connection_daemon.looper.*) == Looper);
        try cancelGateTimer(connection_daemon);
        try std.testing.expectError(error.AlreadyStarted, sut.start());
        // The mock has no event producers and the retry timer is drained.
        // Seed the pre-termination state before delivering looper failure.
        sut.snapshot_publisher.setConnectionStatus(previous_status);
        _ = connection_daemon.gate.updateStatus(previous_status);
        controller.reasserting = previous_status == .connecting;

        const tun = try controller.interface().setTunnelSettings(.{
            .profile = profile,
            .original_module_id = source.net_connection.activeConnectionModule(&profile).?.id(),
        });
        tun.destroy();
        try std.testing.expect(controller.last_settings != null);
        const cleared_before = controller.clear_tunnel_settings_count;
        try daemon.testing.perform(connection_daemon, .onBetterPath);
        try waitForExit(connection_daemon);
        try std.testing.expectError(error.Closed, sut.start());
        try std.testing.expect(sut.state == .stopped);
        try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
        try std.testing.expect(!controller.reasserting);
        try std.testing.expectEqual(cleared_before + 1, controller.clear_tunnel_settings_count);
        try std.testing.expect(controller.last_settings == null);
        // Looper failure is terminal even when protocol cancellation is disabled.
        try std.testing.expectEqual(@as(usize, 1), controller.cancel_count);
        try std.testing.expect(connection_daemon.connection == null);
        try std.testing.expect(!connection_daemon.gate.isReady());
    }
}

test "daemon dispatches controls to actor and owns queued establishment metadata" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Probe = struct {
        looper: *Looper = undefined,
        daemon: *Daemon = undefined,
        profile: *const api.Profile = undefined,
        reachability_count: usize = 0,
        stop_count: usize = 0,
        shutdown_count: usize = 0,
        destroyed: bool = false,

        fn start(_: *anyopaque, _: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
            return .started;
        }
        fn shutdown(raw: *anyopaque, reason: net.Connection.ShutdownReason) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            self.shutdown_count += 1;
            switch (self.shutdown_count) {
                1, 2 => std.debug.assert(reason == .failure and reason.failure == .reconnect),
                else => std.debug.assert(reason == .explicit_stop),
            }
        }
        fn stop(raw: *anyopaque, _: u32, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            std.debug.assert(self.shutdown_count == self.stop_count + 1);
            std.debug.assert(!self.looper.isLinkAttached() and !self.looper.isTunAttached());
            self.stop_count += 1;
            const status = self.daemon.snapshot_publisher.environment.connection_status;
            sink.emit(.stopped);
            std.debug.assert(self.daemon.snapshot_publisher.environment.connection_status == status);
        }
        fn reachability(raw: *anyopaque, _: net.ReachabilityInfo, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            self.reachability_count += 1;
            sink.emit(.{ .data_count = .{} });
        }
        fn betterPath(raw: *anyopaque, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            var servers = [_]api.Address{api.Address.parseRaw("1.1.1.1").?};
            const modules = [_]api.TaggedModule{.{ .DNS = .{
                .id = "11111111-1111-4111-8111-111111111111".*,
                .servers = &servers,
            } }};
            sink.emit(.{ .established = .{
                .remote_endpoint = net.SocketEndpoint.init(api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?) catch unreachable,
                .info = .{
                    .profile = self.profile.*,
                    .original_module_id = "11111111-1111-4111-8111-111111111111".*,
                    .modules = &modules,
                },
            } });
            // This storage expires before the actor can process established.
            servers[0] = api.Address.parseRaw("9.9.9.9").?;
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            self.destroyed = true;
        }
        fn create(raw: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.looper = @ptrCast(@alignCast(sb.writer.?.ptr));
            self.profile = sb.profile;
            return .{ .ptr = self, .vtable = &vtable, .daemon_io = .link };
        }
        fn endpoints(_: *anyopaque) ?[]const api.ExtendedEndpoint {
            const list = struct {
                const value = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
            };
            return &list.value;
        }
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
        const vtable = net.Connection.VTable{
            .endpoints = endpoints,
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
    var probe = Probe{};
    var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &probe, .vtable = &Probe.implementation }});
    defer registry.deinit(allocator);
    var controller = mock_mod.MockTunnelController{ .set_tunnel_settings_error = error.TunNotAvailable };
    var controller_vtable = controller.interface().vtable.*;
    // Retain the recorded payload after the deliberately failed setup.
    controller_vtable.clear_tunnel_settings = struct {
        fn call(_: ?*anyopaque, _: bool) void {}
    }.call;
    var monitor = mock_mod.MockNetworkMonitor{ .reachable = false };
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
    probe.daemon = sut;
    // Publish the runtime on its actor through the normal startup path.
    try sut.start();
    defer sut.stop();
    // Test delayed gate readiness independently of automatic connection starts.
    connection_daemon.gate.setReadyHandler(null);
    monitor.reachable = true;

    // The factory rejects the link. The delayed callback must reenable the
    // gate even though no connection session ever started or emitted events.
    connection_daemon.gate.setReachabilityBlock(reachabilityBlock(&monitor));
    _ = connection_daemon.gate.setEnabled(true);
    sut.options.reconnection_delay_ms = 10;
    try daemon.testing.evaluateConnection(connection_daemon);
    try waitForGate(connection_daemon);
    try std.testing.expect(connection_daemon.gate.isReady());
    try std.testing.expectEqual(@as(usize, 0), probe.stop_count);
    sut.options.reconnection_delay_ms = 60_000;

    try daemon.testing.perform(connection_daemon, .{ .onReachability = .{ .reachable = false } });
    // Seed a connecting session for the synthetic establishment event after
    // the failed preparation has returned the real attempt to disconnected.
    try daemon.testing.onLoop(connection_daemon, sut, struct {
        fn run(_: anytype, state: *Daemon) daemon.Error!void {
            state.snapshot_publisher.setConnectionStatus(.connecting);
        }
    }.run);
    try daemon.testing.perform(connection_daemon, .onBetterPath);
    try daemon.testing.resumeGate(connection_daemon); // Drain establishment and setup failure.
    try std.testing.expectEqual(@as(usize, 1), probe.reachability_count);
    try std.testing.expectEqual(@as(usize, 1), controller.set_tunnel_settings_count);
    try std.testing.expectEqualStrings("1.1.1.1", controller.last_settings.?.dnsServer(0));
    // The controller rejects establishment; stopping it also runs on actor.
    try std.testing.expectEqual(@as(usize, 1), probe.stop_count);
    // A protocol failure must finalize the attempt just like setup failure:
    // shutdown and stop must run in order on the actor before status changes.
    try daemon.testing.perform(connection_daemon, .{ .onConnectionEvent = .{ .failed = .{
        .err_pair = .{ .code = .ioFailure },
        .disposition = .reconnect,
    } } });
    try daemon.testing.resumeGate(connection_daemon); // Confirm stopped reporting completed.
    try std.testing.expectEqual(@as(usize, 2), probe.shutdown_count);
    try std.testing.expectEqual(@as(usize, 2), probe.stop_count);
    try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expect(!probe.destroyed);
    sut.stop();
    try std.testing.expectEqual(@as(usize, 3), probe.stop_count);
    try std.testing.expect(probe.destroyed);
}

test "daemon preserves settings-only failure and hold behavior" {
    const Recorder = struct {
        caller_thread: std.Thread.Id,
        callbacks_on_caller: bool = true,
        last_error: ?api.PartoutErrorCode = null,
        fn status(_: *anyopaque, _: api.ConnectionStatus) void {}
        fn dataCount(_: *anyopaque, _: api.DataCount) void {}
        fn lastError(ctx: *anyopaque, err_pair: api.PartoutErrorPair) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.callbacks_on_caller = self.callbacks_on_caller and std.Thread.getCurrentId() == self.caller_thread;
            self.last_error = err_pair.code;
        }
        fn remove(ctx: *anyopaque, key: daemon.EventKey) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.callbacks_on_caller = self.callbacks_on_caller and std.Thread.getCurrentId() == self.caller_thread;
            if (key == .last_error_code) self.last_error = null;
        }
        fn failSettings(_: ?*anyopaque, _: api.TunnelRemoteInfoWrapper) net.TunnelController.Error!*net.TunWrapper {
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

test "settings daemon creation rolls back allocation failures" {
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

test "daemon owns the profile and rolls back connection startup allocations" {
    const Factory = struct {
        create_count: usize = 0,
        destroy_count: usize = 0,
        writer: ?net.ConnectionWriter = null,
        profile: ?*const api.Profile = null,
        const endpoint_list = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
        fn endpoints(_: *anyopaque) ?[]const api.ExtendedEndpoint {
            return &endpoint_list;
        }
        fn create(ptr: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.create_count += 1;
            self.writer = sb.writer;
            self.profile = sb.profile;
            return .{ .ptr = self, .vtable = &vtable, .daemon_io = .none };
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
            try std.testing.expectEqual(factory.create_count, factory.destroy_count);
            try std.testing.expectEqual(@as(usize, 0), monitor.start_count);
            // Failed startup remains retryable and retains profile ownership.
            try sut.start();
            defer sut.stop();
            try std.testing.expectEqual(&sut.profile, factory.profile.?);
            try std.testing.expect(factory.writer != null);
            sut.stop();
            try std.testing.expectEqual(factory.create_count, factory.destroy_count);
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
    terminal_daemon: ?*Daemon = null,
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

    fn start(ptr: *anyopaque, _: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
        const self: *FailingStartConnection = @ptrCast(@alignCast(ptr));
        self.start_count += 1;
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

test "daemon defers reporting with owned payloads and permits reentrant stop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Factory = struct {
        events: ?net.Connection.Events = null,
        producer_thread: ?std.Thread.Id = null,
        daemon: *Daemon = undefined,
        delivered_updates: *const usize = undefined,
        reporting_inline: bool = false,
        producing: bool = false,

        fn create(raw: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.events = sb.events;
            return .{ .ptr = self, .vtable = &vtable, .daemon_io = .none };
        }
        fn betterPath(raw: *anyopaque, sink: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.producer_thread = std.Thread.getCurrentId();
            self.producing = true;
            defer self.producing = false;
            var key = "OpenVPN.serverConfiguration".*;
            var value = "{\"test\":true}".*;
            // Deferred reporting must copy strings before the producer changes them.
            sink.emit(.{ .set_env = .{ .key = &key, .value = &value } });
            self.daemon.snapshot_publisher.setConnectionStatus(.connected);
            sink.emit(.{ .data_count = .{ .received = 10, .sent = 20 } });
            self.reporting_inline = self.delivered_updates.* == 1 and
                self.daemon.snapshot_publisher.environment.data_count.received == 10 and
                self.daemon.snapshot_publisher.environment.data_count.sent == 20;
            @memset(&key, 'x');
            @memset(&value, 'x');
        }
        fn stop(_: *anyopaque, _: u32, sink: net.Connection.Events) void {
            sink.emit(.{ .set_env = .{ .key = "OpenVPN.serverConfiguration", .value = null } });
            sink.emit(.stopped);
        }
        const endpoint_list = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
        fn endpoints(_: *anyopaque) ?[]const api.ExtendedEndpoint {
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
        factory: *Factory = undefined,
        stop_on_update: bool = false,
        delivered_outside_producer: bool = true,

        fn setEnvironment(raw: ?*anyopaque, key: []const u8, value: ?[]const u8) void {
            const mock: *mock_mod.MockTunnelController = @ptrCast(@alignCast(raw.?));
            const self: *@This() = @fieldParentPtr("mock", mock);
            const current = std.Thread.getCurrentId();
            if (self.delivery_thread) |previous| std.debug.assert(previous == current);
            self.delivery_thread = current;
            self.valid_payload = self.valid_payload and std.mem.eql(u8, key, "OpenVPN.serverConfiguration");
            if (value) |bytes| {
                self.updates += 1;
                self.delivered_outside_producer = self.delivered_outside_producer and !self.factory.producing;
                if (self.stop_on_update) self.factory.daemon.stop();
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
    factory.daemon = sut;
    factory.delivered_updates = &controller.updates;
    controller.factory = &factory;
    try sut.start();
    defer sut.stop();
    const actor = sut.implementation.connection;
    try daemon.testing.perform(actor, .onBetterPath);
    try daemon.testing.resumeGate(actor);
    try std.testing.expect(!factory.reporting_inline);
    try std.testing.expectEqual(@as(usize, 1), controller.updates);
    try std.testing.expect(controller.valid_payload);
    try std.testing.expectEqual(factory.producer_thread.?, controller.delivery_thread.?);
    try std.testing.expect(controller.delivery_thread.? != std.Thread.getCurrentId());

    controller.stop_on_update = true;
    try daemon.testing.perform(actor, .onBetterPath);
    try daemon.testing.resumeGate(actor);
    try daemon.testing.resumeGate(actor);
    try std.testing.expect(controller.delivered_outside_producer);
    try std.testing.expectEqual(@as(usize, 1), controller.clears);
    // A late update must not recreate environment state after shutdown.
    const sink = factory.events.?;
    try daemon.testing.onLoop(actor, sink, struct {
        fn run(_: anytype, events: net.Connection.Events) daemon.Error!void {
            events.emit(.{ .set_env = .{ .key = "OpenVPN.serverConfiguration", .value = "stale" } });
            events.emit(.{ .data_count = .{ .received = 99, .sent = 99 } });
            events.emit(.stopped);
        }
    }.run);
    try daemon.testing.resumeGate(actor);
    try std.testing.expectEqual(@as(usize, 2), controller.updates);
    try std.testing.expectEqual(@as(u64, 0), sut.snapshot_publisher.environment.data_count.received);
    try std.testing.expect(controller.valid_payload);
}

test "I/O modes control socket creation, attachment, and descriptor handoff" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Probe = struct {
        endpoint: api.ExtendedEndpoint,
        endpoint_list: [4]api.ExtendedEndpoint = undefined,
        daemon_io: net.Connection.DaemonIO,
        sync_establish: bool,
        daemon: *Daemon = undefined,
        startup_reachability_pending: bool = false,
        startup_reachability_saw_commit: bool = false,
        events: net.Connection.Events = undefined,
        profile: *const api.Profile = undefined,
        established_tun: ?io.TunDescriptor = null,
        controller: mock_mod.MockTunnelController = .{},
        link_attached: bool = false,
        link_port: u16 = 0,
        tun_fd: io.FileDescriptor = undefined,
        socket_connected: ?bool = null,
        remote: ?net.RemoteDescriptor = null,
        start_count: usize = 0,
        startup_count_reports: usize = 0,
        commit_count: usize = 0,
        commit_error: ?net.ConnectionStartError = null,
        tun_cleanup_count: usize = 0,
        rebind_count: usize = 0,
        recreate_tun: bool = false,
        fn endpoints(raw: *anyopaque) ?[]const api.ExtendedEndpoint {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return &self.endpoint_list;
        }
        fn create(raw: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.endpoint_list = .{ self.endpoint, self.endpoint, self.endpoint, self.endpoint };
            self.events = sb.events.?;
            self.profile = sb.profile;
            return .{ .ptr = self, .vtable = &vtable, .daemon_io = self.daemon_io };
        }
        fn start(raw: *anyopaque, remote: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            self.start_count += 1;
            self.remote = remote;
            self.link_attached = self.daemon.implementation.connection.looper.isLinkAttached();
            self.link_port = if (remote.link) |link| (link.localAddress() catch return error.UnableToStart).port else 0;
            if (self.daemon_io == .looper) return .failed;
            const info = api.TunnelRemoteInfoWrapper{
                .profile = self.profile.*,
                .original_module_id = source.net_connection.activeConnectionModule(self.profile).?.id(),
            };
            if (self.sync_establish) {
                // Queue an event ahead of where an asynchronous established event
                // would land. It must see commit completed when the actor resumes.
                self.startup_reachability_pending = true;
                daemon.testing.schedule(self.daemon.implementation.connection, .{ .onReachability = .{ .reachable = true } }) catch return error.UnableToStart;
                // WireGuard reports its initial counters before returning success.
                self.events.emit(.{ .data_count = .{ .received = 123, .sent = 456 } });
                return .{ .established = .{ .info = info.clone(std.testing.allocator) catch return error.OutOfMemory } };
            }
            self.events.emit(.{ .established = .{ .info = info } });
            self.events.emit(.{ .data_count = .{ .received = 123, .sent = 456 } });
            return .started;
        }
        fn reportDataCount(raw: *anyopaque, count: api.DataCount) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            std.debug.assert(self.commit_count == 1 and self.established_tun != null);
            std.debug.assert(self.daemon.snapshot_publisher.environment.connection_status == .connected);
            std.debug.assert(count.received == 123 and count.sent == 456);
            self.startup_count_reports += 1;
        }
        fn status(_: *anyopaque, _: api.ConnectionStatus) void {}
        fn lastErrorEvent(_: *anyopaque, _: api.PartoutErrorPair) void {}
        fn remove(_: *anyopaque, _: daemon.EventKey) void {}
        fn commit(raw: *anyopaque, tun: io.TunDescriptor) net.ConnectionStartError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.commit_count += 1;
            errdefer tun.cleanup();
            if (self.commit_error) |err| return err;
            self.established_tun = tun;
        }
        fn rebind(raw: *anyopaque, remote: net.RemoteDescriptor, tun: ?net.TunDescriptor) net.ConnectionStartError!bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.established_tun != null);
            if (self.remote.?.link) |link| link.cleanup();
            self.remote = remote;
            std.debug.assert((tun != null) == self.recreate_tun);
            if (tun) |descriptor| {
                self.established_tun.?.cleanup();
                self.established_tun = descriptor;
            }
            self.rebind_count += 1;
            // Requests arriving during the handoff must also be coalesced.
            self.events.emit(.{ .needs_rebind = null });
            return true;
        }
        fn betterPath(raw: *anyopaque, events: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // Event storage may disappear as soon as emit returns.
            var info = api.TunnelRemoteInfoWrapper{ .profile = self.profile.* };
            info = info.clone(std.testing.allocator) catch unreachable;
            defer info.deinit(std.testing.allocator);
            const payload: ?api.TunnelRemoteInfoWrapper = if (self.recreate_tun) info else null;
            events.emit(.{ .needs_rebind = payload });
            events.emit(.{ .needs_rebind = payload });
        }
        fn networkChange(raw: *anyopaque, _: net.ReachabilityInfo, events: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.startup_reachability_pending) {
                self.startup_reachability_pending = false;
                self.startup_reachability_saw_commit = self.commit_count == 1;
                return;
            }
            betterPath(raw, events);
        }
        fn stop(raw: *anyopaque, _: u32, _: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.daemon_io != .looper) {
                if (self.remote) |remote| if (remote.link) |link| link.cleanup();
                self.remote = null;
                if (self.established_tun) |tun| tun.cleanup();
                self.established_tun = null;
            }
        }
        fn socket(raw: ?*anyopaque, allocator: std.mem.Allocator, endpoint: ?api.ExtendedEndpoint, port: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!Looper.LinkDescriptor {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.socket_connected = endpoint != null;
            // The factory probe records the requested mode; use a real local UDP
            // descriptor so daemon attachment and cleanup also execute.
            const wrapper = try io.SocketWrapper.create(allocator, null, .{ .port = port }) orelse return error.LinkNotActive;
            return wrapper.linkDescriptor();
        }
        fn setTunnel(raw: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) net.TunnelController.Error!*io.TunWrapper {
            const controller: *mock_mod.MockTunnelController = @ptrCast(@alignCast(raw.?));
            const self: *@This() = @fieldParentPtr("controller", controller);
            const tun = try controller.interface().setTunnelSettings(info);
            // Borrow the link fd when present; a handed-off mock TUN needs no native fd.
            tun.test_descriptor = .{ .fd = self.tun_fd, .io = .{ .mock = .{ .ptr = self, .vtable = &tun_vtable } } };
            return tun;
        }
        fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
        fn reset(_: *anyopaque) io.Error!void {}
        fn read(_: *anyopaque, _: []u8) io.Error!?usize {
            return error.WouldBlock;
        }
        fn write(_: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
            return data.len - offset;
        }
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tun_cleanup_count += 1;
        }
        fn lastError(_: *anyopaque) c_int {
            return 0;
        }
        const tun_vtable = source.net_io_posix.POSIXInterface.Mock.VTable{
            .set_event_mask = mask,
            .reset_events = reset,
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .last_error_code = lastError,
        };
        const vtable = blk: {
            var table = FailingStartConnection.vtable;
            table.endpoints = endpoints;
            table.start = start;
            table.commit = commit;
            table.rebind = rebind;
            table.better_path = betterPath;
            table.network_change = networkChange;
            table.stop = stop;
            break :blk table;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const allocator = std.testing.allocator;
    const scenarios = [_]struct { mode: net.Connection.DaemonIO, sync_establish: bool = true, recreate_tun: bool = false, err: ?net.ConnectionStartError = null }{
        .{ .mode = .none },
        .{ .mode = .link },
        .{ .mode = .looper },
        .{ .mode = .none, .recreate_tun = true },
        .{ .mode = .link, .recreate_tun = true },
        .{ .mode = .none, .sync_establish = false },
        .{ .mode = .link, .sync_establish = false },
        .{ .mode = .none, .sync_establish = false, .err = error.UnableToStart },
        .{ .mode = .link, .sync_establish = false, .err = error.OutOfMemory },
        .{ .mode = .none, .err = error.UnableToStart },
        .{ .mode = .link, .err = error.UnableToStart },
        .{ .mode = .none, .err = error.OutOfMemory },
        .{ .mode = .link, .err = error.OutOfMemory },
    };
    for ([_]api.IPSocketType{ .udp, .udp4, .udp6, .tcp, .tcp4, .tcp6 }) |proto| {
        for (scenarios) |scenario| {
            const daemon_io = scenario.mode;
            const commit_error = scenario.err;
            for ([_]bool{ true, false }) |connect_udp| {
                var probe = Probe{ .recreate_tun = scenario.recreate_tun, .daemon_io = daemon_io, .sync_establish = scenario.sync_establish, .commit_error = commit_error, .endpoint = api.ExtendedEndpoint.init(if (proto == .udp6 or proto == .tcp6) "::1" else "127.0.0.1", .init(proto, 1194)).? };
                var tun_pipe: [2]std.c.fd_t = undefined;
                if (std.c.pipe(&tun_pipe) != 0) return error.PipeFailed;
                defer _ = std.c.close(tun_pipe[0]);
                defer _ = std.c.close(tun_pipe[1]);
                probe.tun_fd = tun_pipe[0];
                var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &probe, .vtable = &Probe.implementation }});
                defer registry.deinit(allocator);
                var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
                defer profile.deinit(allocator);
                var controller_table = probe.controller.interface().vtable.*;
                controller_table.set_tunnel_settings = Probe.setTunnel;
                var monitor = mock_mod.MockNetworkMonitor{};
                var factory_table = mock_mod.noopSocketFactory().vtable.*;
                factory_table.create = Probe.socket;
                const sut = try Daemon.create(allocator, &profile, .{
                    .objects = .{ .registry = &registry, .controller = .{ .ptr = &probe.controller, .vtable = &controller_table }, .resolver = mock_mod.noopDNSResolver(), .factory = .{ .ptr = &probe, .vtable = &factory_table }, .monitor = monitor.interface() },
                    .options = .{ .connection_options = .{ .connect_udp = connect_udp }, .reconnection_delay_ms = 60_000, .events = .{ .ctx = &probe, .status = Probe.status, .last_error = Probe.lastErrorEvent, .data_count = Probe.reportDataCount, .remove_key = Probe.remove } },
                });
                defer sut.destroy();
                probe.daemon = sut;
                try sut.start();
                defer sut.stop();
                try waitForConnectionRequest(sut.implementation.connection);
                try std.testing.expectError(error.AlreadyStarted, sut.start());
                try waitForConnectionRequest(sut.implementation.connection);
                try std.testing.expectError(error.AlreadyStarted, sut.start());
                if (scenario.sync_establish and daemon_io != .looper) {
                    try std.testing.expect(probe.startup_reachability_saw_commit);
                }
                try std.testing.expectEqual(@as(usize, if (daemon_io != .looper and commit_error == null) 1 else 0), probe.startup_count_reports);
                if (commit_error) |err| {
                    try std.testing.expectEqual(@as(u64, 0), sut.snapshot_publisher.environment.data_count.received);
                    try std.testing.expectEqual(@as(usize, 1), probe.commit_count);
                    try std.testing.expectEqual(@as(usize, 1), probe.tun_cleanup_count);
                    try std.testing.expect(probe.established_tun == null);
                    try std.testing.expect(probe.remote == null);
                    try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
                    try std.testing.expectEqual(daemon.testing.codeForDaemonStartError(err), sut.snapshot_publisher.last_error.?.code);
                    for (sut.test_status_history[0..sut.test_status_count]) |status| {
                        try std.testing.expect(status != .connected);
                    }
                    continue;
                }
                try std.testing.expectEqual(daemon_io == .looper, probe.link_attached);
                if (daemon_io == .none) {
                    try std.testing.expect(probe.remote.?.link == null);
                    try std.testing.expect(probe.remote.?.endpoint == null);
                    try std.testing.expectEqual(@as(u16, 0), probe.link_port);
                    try std.testing.expect(probe.socket_connected == null);
                } else {
                    try std.testing.expect(probe.link_port != 0);
                }
                if (daemon_io != .looper) {
                    const owner = sut.implementation.connection;
                    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
                    try std.testing.expectEqual(@as(u64, 123), sut.snapshot_publisher.environment.data_count.received);
                    try std.testing.expectEqual(@as(u64, 456), sut.snapshot_publisher.environment.data_count.sent);
                    try std.testing.expect(probe.established_tun != null);
                    try std.testing.expect(!owner.looper.isLinkAttached() and !owner.looper.isTunAttached());
                }
                if (daemon_io != .none) {
                    const peer = probe.remote.?.endpoint.?;
                    try std.testing.expectEqual(proto, peer.type);
                    try std.testing.expectEqual(@as(u16, 1194), peer.address.port);
                    try std.testing.expectEqual(connect_udp or peer.plainSocketType() == .tcp, probe.socket_connected.?);
                    if (!probe.socket_connected.?) try std.testing.expect(probe.remote.?.local_port != 0);
                }
                if (daemon_io != .looper) {
                    const owner = sut.implementation.connection;
                    const tun = probe.established_tun.?;
                    try daemon.testing.perform(owner, .onBetterPath);
                    // Duplicate queued requests and requests during handoff share one rebind.
                    try waitForConnectionRequest(sut.implementation.connection);
                    try std.testing.expectError(error.AlreadyStarted, sut.start());
                    try waitForRebind(owner, &probe, 1);
                    try std.testing.expectEqual(@as(usize, 1), probe.rebind_count);
                    try daemon.testing.perform(owner, .{ .onReachability = .{ .reachable = true } });
                    try waitForConnectionRequest(sut.implementation.connection);
                    try std.testing.expectError(error.AlreadyStarted, sut.start());
                    try waitForRebind(owner, &probe, 2);
                    try std.testing.expectEqual(@as(usize, 2), probe.rebind_count);
                    if (daemon_io == .none) {
                        try std.testing.expect(probe.remote.?.link == null);
                        try std.testing.expect(probe.socket_connected == null);
                    }
                    try std.testing.expectEqual(@as(usize, 1), probe.start_count);
                    try std.testing.expectEqual(@as(usize, 1), probe.commit_count);
                    try std.testing.expectEqual(@as(usize, if (scenario.recreate_tun) 3 else 1), probe.controller.set_tunnel_settings_count);
                    try std.testing.expectEqual(@as(usize, if (scenario.recreate_tun) 2 else 0), probe.tun_cleanup_count);
                    try std.testing.expectEqual(tun.fd, probe.established_tun.?.fd);
                    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
                    if (scenario.recreate_tun) {
                        try daemon.testing.onLoop(owner, &probe, struct {
                            fn run(_: anytype, value: *Probe) daemon.Error!void {
                                value.controller.set_tunnel_settings_error = error.TunNotAvailable;
                                Probe.betterPath(value, value.events);
                            }
                        }.run);
                        const deadline = core.monotonicNs() + 2 * std.time.ns_per_s;
                        while (core.monotonicNs() < deadline) {
                            var failed = false;
                            try daemon.testing.onLoop(owner, &failed, struct {
                                fn run(loop: anytype, out: *bool) daemon.Error!void {
                                    out.* = loop.daemon.snapshot_publisher.last_error != null;
                                }
                            }.run);
                            if (failed) break;
                            core.sleepMs(1);
                        }
                        try std.testing.expectEqual(@as(usize, 4), probe.controller.set_tunnel_settings_count);
                        try std.testing.expectEqual(@as(usize, 2), probe.rebind_count);
                        try std.testing.expectEqual(@as(usize, 3), probe.tun_cleanup_count);
                        try std.testing.expect(probe.established_tun == null);
                        try std.testing.expect(probe.remote == null);
                        try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
                        try std.testing.expectEqual(api.PartoutErrorCode.tunNotAvailable, sut.snapshot_publisher.last_error.?.code);
                    }
                }
                sut.stop();
                try std.testing.expect(probe.established_tun == null);
                if (daemon_io != .looper) {
                    try std.testing.expectEqual(@as(usize, if (scenario.recreate_tun) 3 else 1), probe.tun_cleanup_count);
                }
            }
        }
    }
}

test "looper owns TUN across startup and optional rebind replacement" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Probe = struct {
        daemon: *Daemon = undefined,
        profile: *const api.Profile = undefined,
        allocator: std.mem.Allocator = undefined,
        tun_fd: io.FileDescriptor,
        controller: mock_mod.MockTunnelController = .{},
        recreate_tun: bool = false,
        rebind_count: usize = 0,
        tun_cleanup_count: usize = 0,

        fn create(raw: ?*anyopaque, allocator: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.profile = sb.profile;
            self.allocator = allocator;
            return .{ .ptr = self, .vtable = &vtable, .daemon_io = .looper };
        }
        fn start(raw: *anyopaque, _: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const info = api.TunnelRemoteInfoWrapper{ .profile = self.profile.* };
            return .{ .established = .{ .info = info.clone(self.allocator) catch return error.OutOfMemory } };
        }
        fn commit(_: *anyopaque, _: io.TunDescriptor) net.ConnectionStartError!void {
            @panic("looper-owned TUN must not be committed to the connection");
        }
        fn rebind(raw: *anyopaque, remote: net.RemoteDescriptor, tun: ?io.TunDescriptor) net.ConnectionStartError!bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const looper = self.daemon.implementation.connection.looper;
            std.debug.assert(looper.isLinkAttached() and looper.isTunAttached());
            std.debug.assert(remote.link != null);
            std.debug.assert((tun != null) == self.recreate_tun);
            if (tun) |descriptor| std.debug.assert(descriptor.fd == self.tun_fd);
            // Replacing TUN releases its predecessor before borrowing the new one.
            std.debug.assert(self.tun_cleanup_count == @intFromBool(self.recreate_tun));
            self.rebind_count += 1;
            return true;
        }
        fn betterPath(raw: *anyopaque, events: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            events.emit(.{ .needs_rebind = if (self.recreate_tun) .{ .profile = self.profile.* } else null });
        }
        fn socket(_: ?*anyopaque, allocator: std.mem.Allocator, _: ?api.ExtendedEndpoint, port: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!io.LinkDescriptor {
            const wrapper = try io.SocketWrapper.create(allocator, null, .{ .port = port }) orelse return error.LinkNotActive;
            return wrapper.linkDescriptor();
        }
        fn setTunnel(raw: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) net.TunnelController.Error!*io.TunWrapper {
            const controller: *mock_mod.MockTunnelController = @ptrCast(@alignCast(raw.?));
            const self: *@This() = @fieldParentPtr("controller", controller);
            const tun = try controller.interface().setTunnelSettings(info);
            tun.test_descriptor = .{ .fd = self.tun_fd, .io = .{ .mock = .{ .ptr = self, .vtable = &tun_vtable } } };
            return tun;
        }
        fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
        fn reset(_: *anyopaque) io.Error!void {}
        fn read(_: *anyopaque, _: []u8) io.Error!?usize {
            return error.WouldBlock;
        }
        fn write(_: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
            return data.len - offset;
        }
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tun_cleanup_count += 1;
        }
        fn lastError(_: *anyopaque) c_int {
            return 0;
        }
        const tun_vtable = source.net_io_posix.POSIXInterface.Mock.VTable{
            .set_event_mask = mask,
            .reset_events = reset,
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .last_error_code = lastError,
        };
        const vtable = blk: {
            var table = FailingStartConnection.vtable;
            table.start = start;
            table.commit = commit;
            table.rebind = rebind;
            table.better_path = betterPath;
            break :blk table;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const allocator = std.testing.allocator;
    var tun_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&tun_pipe) != 0) return error.PipeFailed;
    defer _ = std.c.close(tun_pipe[0]);
    defer _ = std.c.close(tun_pipe[1]);
    var probe = Probe{ .tun_fd = tun_pipe[0] };
    var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &probe, .vtable = &Probe.implementation }});
    defer registry.deinit(allocator);
    var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
    defer profile.deinit(allocator);
    var controller_table = probe.controller.interface().vtable.*;
    controller_table.set_tunnel_settings = Probe.setTunnel;
    var factory_table = mock_mod.noopSocketFactory().vtable.*;
    factory_table.create = Probe.socket;
    var monitor = mock_mod.MockNetworkMonitor{};
    const sut = try Daemon.create(allocator, &profile, .{
        .objects = .{
            .registry = &registry,
            .controller = .{ .ptr = &probe.controller, .vtable = &controller_table },
            .resolver = mock_mod.noopDNSResolver(),
            .factory = .{ .vtable = &factory_table },
            .monitor = monitor.interface(),
        },
        .options = .{ .reconnection_delay_ms = 60_000 },
    });
    defer sut.destroy();
    probe.daemon = sut;
    try sut.start();
    defer sut.stop();
    const owner = sut.implementation.connection;
    try waitForConnectionRequest(owner);
    try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
    try std.testing.expectEqual(@as(usize, 1), probe.controller.set_tunnel_settings_count);
    for ([_]bool{ false, true }, 1..) |recreate, expected| {
        try daemon.testing.onLoop(owner, recreate, struct {
            fn run(loop: anytype, value: bool) daemon.Error!void {
                const context: *Probe = @ptrCast(@alignCast(loop.connection.?.ptr));
                context.recreate_tun = value;
            }
        }.run);
        try daemon.testing.perform(owner, .onBetterPath);
        try waitForRebind(owner, &probe, expected);
        try std.testing.expectEqual(@as(usize, 1) + @intFromBool(recreate), probe.controller.set_tunnel_settings_count);
        try std.testing.expectEqual(@as(usize, @intFromBool(recreate)), probe.tun_cleanup_count);
        try std.testing.expectEqual(api.ConnectionStatus.connected, sut.snapshot_publisher.environment.connection_status);
    }
    sut.stop();
    try std.testing.expectEqual(@as(usize, 2), probe.tun_cleanup_count);
    try std.testing.expect(!owner.looper.isLinkAttached() and !owner.looper.isTunAttached());
}

test "needs_rebind restarts sessions without reporting a failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Probe = struct {
        starts: usize = 0,
        stops: usize = 0,
        reason: ?net.Connection.ShutdownReason = null,

        fn create(raw: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, _: net.Sandbox) net.ConnectionCreateError!net.Connection {
            return .{ .ptr = raw.?, .vtable = &vtable, .daemon_io = .none };
        }
        fn start(raw: *anyopaque, _: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.starts += 1;
            return .started;
        }
        fn shutdown(raw: *anyopaque, reason: net.Connection.ShutdownReason) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reason = reason;
        }
        fn stop(raw: *anyopaque, _: u32, events: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.stops += 1;
            events.emit(.stopped);
        }
        fn betterPath(_: *anyopaque, events: net.Connection.Events) void {
            events.emit(.{ .needs_rebind = null });
            events.emit(.{ .needs_rebind = null });
        }
        const vtable = blk: {
            var value = FailingStartConnection.vtable;
            value.start = start;
            value.shutdown = shutdown;
            value.stop = stop;
            value.better_path = betterPath;
            break :blk value;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const allocator = std.testing.allocator;
    for ([_]api.ConnectionStatus{ .connecting, .connected }) |status| {
        var probe = Probe{};
        var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &probe, .vtable = &Probe.implementation }});
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
            .options = .{ .starts_immediately = true, .reconnection_delay_ms = 60_000 },
        });
        defer sut.destroy();
        try sut.start();
        defer sut.stop();
        const owner = sut.implementation.connection;
        try daemon.testing.onLoop(owner, status, struct {
            fn run(loop: anytype, previous: api.ConnectionStatus) daemon.Error!void {
                loop.daemon.snapshot_publisher.setConnectionStatus(previous);
                _ = loop.gate.updateStatus(previous);
            }
        }.run);
        try daemon.testing.perform(owner, .onBetterPath);
        // Drain the refresh and its queued stopped event without enabling retries.
        try daemon.testing.onLoop(owner, {}, struct {
            fn run(_: anytype, _: void) daemon.Error!void {}
        }.run);
        try daemon.testing.onLoop(owner, {}, struct {
            fn run(_: anytype, _: void) daemon.Error!void {}
        }.run);
        try std.testing.expectEqual(@as(usize, 1), probe.starts);
        try std.testing.expectEqual(@as(usize, 1), probe.stops);
        try std.testing.expect(probe.reason.? == .rebind);
        try std.testing.expect(sut.snapshot_publisher.last_error == null);
        try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
        try std.testing.expect(owner.conn_request == null);
        try daemon.testing.resumeGate(owner);
        try waitForConnectionRequest(owner);
        try std.testing.expectEqual(@as(usize, 2), probe.starts);
        try std.testing.expectEqual(api.ConnectionStatus.connecting, sut.snapshot_publisher.environment.connection_status);
        try std.testing.expectEqual(@as(usize, 0), controller.cancel_count);
    }
}

test "daemon-created link is released on failed start or rebind" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Scenario = enum { start_false, start_error, rebind_false, rebind_error };
    const Probe = struct {
        scenario: Scenario,
        socket_count: usize = 0,
        start_count: usize = 0,
        rebind_count: usize = 0,
        last_fd: io.FileDescriptor = undefined,
        remote: ?net.RemoteDescriptor = null,
        const endpoint_list = [_]api.ExtendedEndpoint{
            api.ExtendedEndpoint.init("127.0.0.1", .init(.udp, 1194)).?,
            api.ExtendedEndpoint.init("127.0.0.1", .init(.udp, 1195)).?,
        };

        fn endpoints(_: *anyopaque) ?[]const api.ExtendedEndpoint {
            return &endpoint_list;
        }
        fn create(raw: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, _: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .ptr = self, .vtable = &vtable, .daemon_io = .link };
        }
        fn start(raw: *anyopaque, remote: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.start_count += 1;
            self.remote = remote;
            return switch (self.scenario) {
                .start_false => .failed,
                .start_error => error.UnableToStart,
                else => .started,
            };
        }
        fn rebind(raw: *anyopaque, remote: net.RemoteDescriptor, tun: ?net.TunDescriptor) net.ConnectionStartError!bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.remote.?.link.?.cleanup();
            self.remote = remote;
            std.debug.assert(tun == null);
            self.rebind_count += 1;
            return switch (self.scenario) {
                .rebind_false => false,
                .rebind_error => error.UnableToStart,
                else => true,
            };
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.remote) |remote| remote.link.?.cleanup();
            self.remote = null;
        }
        fn stop(raw: *anyopaque, _: u32, _: net.Connection.Events) void {
            destroy(raw);
        }
        fn betterPath(_: *anyopaque, events: net.Connection.Events) void {
            events.emit(.{ .needs_rebind = null });
        }
        fn socket(raw: ?*anyopaque, allocator: std.mem.Allocator, _: ?api.ExtendedEndpoint, port: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!Looper.LinkDescriptor {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const wrapper = try io.SocketWrapper.create(allocator, null, .{ .port = port }) orelse return error.LinkNotActive;
            const descriptor = wrapper.linkDescriptor();
            self.last_fd = descriptor.fd;
            self.socket_count += 1;
            return descriptor;
        }
        const vtable = blk: {
            var value = FailingStartConnection.vtable;
            value.endpoints = endpoints;
            value.start = start;
            value.rebind = rebind;
            value.stop = stop;
            value.destroy = destroy;
            value.better_path = betterPath;
            break :blk value;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const allocator = std.testing.allocator;
    for ([_]Scenario{ .start_false, .start_error, .rebind_false, .rebind_error }) |scenario| {
        var probe = Probe{ .scenario = scenario };
        var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &probe, .vtable = &Probe.implementation }});
        defer registry.deinit(allocator);
        var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
        defer profile.deinit(allocator);
        var controller = mock_mod.MockTunnelController{};
        var monitor = mock_mod.MockNetworkMonitor{};
        var factory_table = mock_mod.noopSocketFactory().vtable.*;
        factory_table.create = Probe.socket;
        const sut = try Daemon.create(allocator, &profile, .{
            .objects = .{ .registry = &registry, .controller = controller.interface(), .resolver = mock_mod.noopDNSResolver(), .factory = .{ .ptr = &probe, .vtable = &factory_table }, .monitor = monitor.interface() },
            .options = .{ .reconnection_delay_ms = 60_000 },
        });
        defer sut.destroy();
        try sut.start();
        defer sut.stop();
        // Wait for initial preparation before requesting a link refresh.
        try waitForConnectionRequest(sut.implementation.connection);
        try std.testing.expectError(error.AlreadyStarted, sut.start());
        const refresh = scenario == .rebind_false or scenario == .rebind_error;
        if (refresh) {
            try std.testing.expectEqual(@as(usize, 1), probe.start_count);
            try std.testing.expectEqual(api.ConnectionStatus.connecting, sut.snapshot_publisher.environment.connection_status);
            try daemon.testing.perform(sut.implementation.connection, .onBetterPath);
            try waitForConnectionRequest(sut.implementation.connection);
            try std.testing.expectError(error.AlreadyStarted, sut.start());
        }
        sut.stop();
        try std.testing.expectEqual(@as(usize, if (refresh) 2 else 1), probe.socket_count);
        try std.testing.expectEqual(@as(usize, 1), probe.start_count);
        try std.testing.expectEqual(@as(usize, if (scenario == .rebind_false or scenario == .rebind_error) 1 else 0), probe.rebind_count);
        try std.testing.expect(probe.remote == null);
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(probe.last_fd, std.c.F.GETFD));
    }
}

test "event loop flushes graceful shutdown and finalizes terminal failure on its thread" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Atomic = std.atomic.Value(usize);
    const Probe = struct {
        daemon: *Daemon = undefined,
        writer: net.ConnectionWriter = undefined,
        fd: io.FileDescriptor,
        timer: io.Timer = .{},
        created: Atomic = .init(0),
        ticks: Atomic = .init(0),
        reads: Atomic = .init(0),
        writes: Atomic = .init(0),
        cleaned: usize = 0,
        destroyed: usize = 0,
        stopped: usize = 0,
        starts: usize = 0,
        termination_count: usize = 0,
        output: [64]u8 = undefined,
        output_len: usize = 0,

        fn onActor(self: *@This()) void {
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
        }
        fn create(raw: ?*anyopaque, _: std.mem.Allocator, _: net.ConnectionModule, sb: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.onActor();
            self.writer = sb.writer.?;
            self.timer = .{};
            _ = self.created.fetchAdd(1, .release);
            return .{ .ptr = self, .vtable = &vtable, .daemon_io = .looper };
        }
        fn endpoints(_: *anyopaque) ?[]const api.ExtendedEndpoint {
            const list = struct {
                const value = [_]api.ExtendedEndpoint{api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?};
            };
            return &list.value;
        }
        fn start(raw: *anyopaque, _: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            std.debug.assert(self.daemon.implementation.connection.looper.isLinkAttached());
            self.starts += 1;
            // The retry timer must reattach LINK outside the looper callback.
            if (self.starts == 1) return .failed;
            self.writer.writePackets(&.{"start"}, .link, null) catch return error.UnableToStart;
            if (self.created.load(.acquire) == 1) {
                self.writer.scheduleTimer(&self.timer, 20, .{ .context = self, .callback = tick }) catch return error.UnableToStart;
            }
            return .started;
        }
        fn tick(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.onActor();
            self.writer.writePackets(&.{"timer"}, .link, null) catch unreachable;
            _ = self.ticks.fetchAdd(1, .release);
        }
        fn submit(raw: *anyopaque, side: io.Side, packets: io.Packets, sources: ?[]const io.SocketAddress) io.ReadAction {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            std.debug.assert(side == .link and sources == null);
            self.writer.writePackets(packets, .link, null) catch unreachable;
            _ = self.reads.fetchAdd(packets.len, .release);
            return .keep;
        }
        fn terminate(raw: *anyopaque, _: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            self.daemon.implementation.connection.looper.stop() catch unreachable;
        }
        fn terminated(raw: *anyopaque, failure: ?io.Failure) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            std.debug.assert(failure == null);
            self.writer.cancelTimer(&self.timer);
            self.termination_count += 1;
        }
        fn shutdown(raw: *anyopaque, _: net.Connection.ShutdownReason) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            self.writer.cancelTimer(&self.timer);
            // The rejected first start has no active protocol to shut down.
            if (self.starts == 1) return;
            self.writer.writePackets(&.{"exit"}, .link, null) catch |err| {
                std.debug.assert(err == error.LooperUnavailable);
            };
        }
        fn stop(raw: *anyopaque, _: u32, _: net.Connection.Events) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            std.debug.assert(!self.daemon.implementation.connection.looper.isLinkAttached());
            self.stopped += 1;
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            self.destroyed += 1;
        }
        fn socket(raw: ?*anyopaque, _: std.mem.Allocator, _: ?api.ExtendedEndpoint, _: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!Looper.LinkDescriptor {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.debug.assert(!daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            return .{ .fd = self.fd, .io = .{ .mock = .{ .ptr = self, .vtable = &io_vtable } } };
        }
        fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
        fn reset(_: *anyopaque) io.Error!void {}
        fn read(raw: *anyopaque, data: []u8) io.Error!?usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            const count = std.c.read(self.fd, data.ptr, data.len);
            if (count < 0) return error.WouldBlock;
            return @intCast(count);
        }
        fn write(raw: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            const remaining = data[offset..];
            @memcpy(self.output[self.output_len..][0..remaining.len], remaining);
            self.output_len += remaining.len;
            _ = self.writes.fetchAdd(1, .release);
            return remaining.len;
        }
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.onActor();
            self.cleaned += 1;
        }
        fn code(_: *anyopaque) c_int {
            return 0;
        }
        fn wait(value: *const Atomic, expected: usize) !void {
            const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
            while (value.load(.acquire) < expected) {
                if (core.monotonicNs() >= deadline) return error.Timeout;
                core.sleepMs(1);
            }
        }
        const io_vtable = source.net_io_posix.POSIXInterface.Mock.VTable{
            .set_event_mask = mask,
            .reset_events = reset,
            .read = read,
            .write = write,
            .cleanup = cleanup,
            .last_error_code = code,
        };
        const vtable = blk: {
            var table = FailingStartConnection.vtable;
            table.endpoints = endpoints;
            table.start = start;
            table.submit_packets = submit;
            table.better_path = terminate;
            table.looper_terminated = terminated;
            table.shutdown = shutdown;
            table.stop = stop;
            table.destroy = destroy;
            break :blk table;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
    };
    const Shutdown = enum { terminal, stop, reconnect };
    for ([_]Shutdown{ .terminal, .stop, .reconnect }) |shutdown| {
        const terminal = shutdown == .terminal;
        var fds: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(0, std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        defer _ = std.c.close(fds[1]);
        const flags = std.c.fcntl(fds[0], std.c.F.GETFL, @as(c_int, 0));
        try std.testing.expect(flags >= 0);
        try std.testing.expect(std.c.fcntl(fds[0], std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) >= 0);
        const allocator = std.testing.allocator;
        var probe = Probe{ .fd = fds[0] };
        var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &probe, .vtable = &Probe.implementation }});
        defer registry.deinit(allocator);
        var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
        defer profile.deinit(allocator);
        var controller = mock_mod.MockTunnelController{};
        var monitor = mock_mod.MockNetworkMonitor{};
        var factory_table = mock_mod.noopSocketFactory().vtable.*;
        factory_table.create = Probe.socket;
        const sut = try Daemon.create(allocator, &profile, .{
            .objects = .{
                .registry = &registry,
                .controller = controller.interface(),
                .resolver = mock_mod.noopDNSResolver(),
                .factory = .{ .ptr = &probe, .vtable = &factory_table },
                .monitor = monitor.interface(),
            },
            .options = .{ .starts_immediately = true, .reconnection_delay_ms = 1, .connection_options = .{ .connect_udp = true } },
        });
        defer sut.destroy();
        probe.daemon = sut;
        try sut.start();
        defer sut.stop();
        // The actor drives these writes and timer while its mailbox is idle.
        try Probe.wait(&probe.writes, 2);
        try std.testing.expectEqual(@as(usize, 1), probe.ticks.load(.acquire));
        try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], "in", 2));
        try Probe.wait(&probe.writes, 3);
        try std.testing.expectEqual(@as(usize, 1), probe.reads.load(.acquire));
        const owner = sut.implementation.connection;
        if (terminal) {
            // Terminal failure finalizes without a usable link and cancels the host.
            try daemon.testing.perform(owner, .onBetterPath);
            try waitForExit(owner);
        } else {
            if (shutdown == .reconnect) {
                // Keep the next attempt dormant while inspecting failure shutdown.
                try daemon.testing.onLoop(owner, {}, struct {
                    fn run(loop: anytype, _: void) daemon.Error!void {
                        loop.daemon.options.reconnection_delay_ms = 60_000;
                    }
                }.run);
                try daemon.testing.perform(owner, .{ .onConnectionEvent = .{ .failed = .{
                    .err_pair = .{ .code = .networkChanged },
                    .disposition = .reconnect,
                } } });
                try std.testing.expectEqualStrings("starttimerinexit", probe.output[0..probe.output_len]);
                try std.testing.expectEqual(@as(usize, 2), probe.stopped);
                try std.testing.expectEqual(@as(usize, 0), probe.destroyed);
            }
            // Both reconnect and explicit stop must flush before detaching LINK.
            sut.stop();
        }
        try std.testing.expectEqual(@as(usize, 1), probe.created.load(.acquire));
        try std.testing.expectEqualStrings(if (terminal) "starttimerin" else "starttimerinexit", probe.output[0..probe.output_len]);
        try std.testing.expectEqual(@as(usize, if (terminal) 3 else 4), probe.writes.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), probe.starts);
        try std.testing.expectEqual(@as(usize, 2), probe.cleaned);
        try std.testing.expectEqual(@as(usize, 1), probe.destroyed);
        try std.testing.expectEqual(@as(usize, if (shutdown == .reconnect) 3 else 2), probe.stopped);
        try std.testing.expectEqual(@as(usize, if (terminal) 1 else 0), controller.cancel_count);
        if (terminal) try std.testing.expectError(error.Closed, daemon.testing.resumeGate(owner));
        try std.testing.expect(sut.state == .stopped);
    }
}

fn cancelGateTimer(owner: anytype) !void {
    try daemon.testing.onLoop(owner, {}, struct {
        fn run(loop: anytype, _: void) daemon.Error!void {
            loop.looper.cancelTimer(&loop.resume_gate_timer);
        }
    }.run);
}

fn waitForConnectionRequest(owner: anytype) !void {
    const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
    while (core.monotonicNs() < deadline) {
        var finished = false;
        try daemon.testing.onLoop(owner, &finished, struct {
            fn run(loop: anytype, out: *bool) daemon.Error!void {
                out.* = loop.conn_request == null;
            }
        }.run);
        if (finished) return;
        core.sleepMs(1);
    }
    return error.Timeout;
}

fn waitForRebind(owner: anytype, probe: anytype, expected: usize) !void {
    const deadline = core.monotonicNs() + 2 * std.time.ns_per_s;
    const Context = struct { probe: @TypeOf(probe), expected: usize, done: bool = false };
    var context = Context{ .probe = probe, .expected = expected };
    while (core.monotonicNs() < deadline) {
        try daemon.testing.onLoop(owner, &context, struct {
            fn run(loop: anytype, state: *Context) daemon.Error!void {
                state.done = loop.conn_request == null and state.probe.rebind_count == state.expected;
            }
        }.run);
        if (context.done) return;
        core.sleepMs(1);
    }
    return error.Timeout;
}

fn waitForGate(owner: anytype) !void {
    const deadline = core.monotonicNs() + 2 * std.time.ns_per_s;
    while (core.monotonicNs() < deadline) {
        var ready = false;
        try daemon.testing.onLoop(owner, &ready, struct {
            fn run(loop: anytype, out: *bool) daemon.Error!void {
                out.* = loop.gate.isReady();
            }
        }.run);
        if (ready) return;
        core.sleepMs(1);
    }
    return error.Timeout;
}

fn waitForExit(owner: anytype) !void {
    const deadline = core.monotonicNs() + 2 * std.time.ns_per_s;
    while (core.monotonicNs() < deadline) {
        owner.jobs_mutex.lock();
        const exited = owner.actor_id == null;
        owner.jobs_mutex.unlock();
        if (exited) return;
        core.sleepMs(1);
    }
    return error.Timeout;
}

test "event loop completes pending performs and releases discarded payloads on shutdown" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var connection = FailingStartConnection{};
    var registry = try net.ConnectionRegistry.init(allocator, &.{connection.implementation()});
    defer registry.deinit(allocator);
    var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
    defer profile.deinit(allocator);
    var controller = mock_mod.MockTunnelController{};
    var monitor = mock_mod.MockNetworkMonitor{ .reachable = false };
    const sut = try Daemon.create(allocator, &profile, .{
        .objects = .{
            .registry = &registry,
            .controller = controller.interface(),
            .resolver = mock_mod.noopDNSResolver(),
            .factory = mock_mod.noopSocketFactory(),
            .monitor = monitor.interface(),
        },
        .options = .{},
    });
    defer sut.destroy();
    try sut.start();
    defer sut.stop();
    const owner = sut.implementation.connection;

    // Nested perform executes inline and preserves its domain error.
    var nested_error = false;
    try daemon.testing.onLoop(owner, &nested_error, struct {
        fn run(loop: anytype, saw_error: *bool) daemon.Error!void {
            daemon.testing.perform(loop, .start) catch |err| {
                saw_error.* = err == error.AlreadyStarted;
                return;
            };
        }
    }.run);
    try std.testing.expect(nested_error);
    try std.testing.expectError(error.AlreadyStarted, sut.start());

    const Probe = struct {
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        waiter_closed: std.atomic.Value(bool) = .init(false),
        blocker_error: ?anyerror = null,
        fn block(loop: anytype, self: *@This()) daemon.Error!void {
            std.debug.assert(daemon.testing.isCurrentThread(loop));
            self.entered.store(true, .release);
            const deadline = core.monotonicNs() + 2 * std.time.ns_per_s;
            while (!self.released.load(.acquire) and core.monotonicNs() < deadline) core.sleepMs(1);
        }
        fn blocker(loop: anytype, self: *@This()) void {
            daemon.testing.onLoop(loop, self, block) catch |err| {
                self.blocker_error = err;
            };
        }
        fn waiter(loop: anytype, self: *@This()) void {
            daemon.testing.perform(loop, .start) catch |err| {
                self.waiter_closed.store(err == error.Closed, .release);
            };
        }
    };
    var probe = Probe{};
    const blocker = try std.Thread.spawn(.{}, Probe.blocker, .{ owner, &probe });
    defer blocker.join();
    defer probe.released.store(true, .release);
    const deadline = core.monotonicNs() + std.time.ns_per_s;
    while (!probe.entered.load(.acquire)) {
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }

    // Successful enqueue transfers these allocations to the event loop.
    const info = api.TunnelRemoteInfoWrapper{
        .profile = profile,
        .original_module_id = source.net_connection.activeConnectionModule(&profile).?.id(),
    };
    // The testing allocator detects leaks if discarded establishment metadata is retained.
    try daemon.testing.schedule(owner, .{ .onConnectionEvent = .{ .established = .{ .info = try info.clone(allocator) } } });
    const waiter = try std.Thread.spawn(.{}, Probe.waiter, .{ owner, &probe });
    defer waiter.join();
    defer probe.released.store(true, .release);
    while (true) {
        owner.jobs_mutex.lock();
        const queued = if (owner.jobs.tail) |tail| !tail.owned else false;
        owner.jobs_mutex.unlock();
        if (queued) break;
        if (core.monotonicNs() >= deadline) return error.Timeout;
        core.sleepMs(1);
    }
    daemon.testing.shutdown(owner);
    probe.released.store(true, .release);
    try waitForExit(owner);
    const completion_deadline = core.monotonicNs() + std.time.ns_per_s;
    while (!probe.waiter_closed.load(.acquire)) {
        if (core.monotonicNs() >= completion_deadline) return error.Timeout;
        core.sleepMs(1);
    }
    try std.testing.expect(sut.state == .stopped);
    try std.testing.expectEqual(@as(usize, 0), controller.cancel_count);
    try std.testing.expectError(error.Closed, daemon.testing.resumeGate(owner));
    try std.testing.expectError(error.Closed, daemon.testing.schedule(owner, .onBetterPath));
}

test "terminal protocol failure pauses retries and honors cancellation policy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |cancels| {
        var connection = FailingStartConnection{};
        var registry = try net.ConnectionRegistry.init(allocator, &.{connection.implementation()});
        defer registry.deinit(allocator);
        var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
        defer profile.deinit(allocator);
        var controller = mock_mod.MockTunnelController{};
        var recorder = mock_mod.DaemonEventRecorder{};
        var monitor = mock_mod.MockNetworkMonitor{ .reachable = false };
        const sut = try Daemon.create(allocator, &profile, .{
            .objects = .{
                .registry = &registry,
                .controller = controller.interface(),
                .resolver = mock_mod.noopDNSResolver(),
                .factory = mock_mod.noopSocketFactory(),
                .monitor = monitor.interface(),
            },
            .options = .{ .events = recorder.events(), .cancels_unrecoverable = cancels },
        });
        defer sut.destroy();
        try sut.start();
        defer sut.stop();
        const owner = sut.implementation.connection;
        try daemon.testing.perform(owner, .{ .onConnectionEvent = .{ .failed = .{
            .err_pair = api.openVPNErrorPair(.tlsFailure),
            .disposition = .cancel,
        } } });
        try std.testing.expect(sut.state == .failed);
        try std.testing.expect(!owner.gate.isReady());
        try std.testing.expectEqual(@as(usize, if (cancels) 1 else 0), controller.cancel_count);
        try std.testing.expectEqualStrings("openVPN.tlsFailure", recorder.last_error_raw[0..recorder.last_error_len]);
        if (cancels) try std.testing.expectEqualStrings("openVPN.tlsFailure", controller.last_cancel_raw[0..controller.last_cancel_len]);
        const snapshots = controller.report_snapshot_count;
        try daemon.testing.resumeGate(owner);
        try std.testing.expectEqual(snapshots, controller.report_snapshot_count);
        sut.hold();
        try std.testing.expect(sut.state == .stopped);
        try std.testing.expectEqualStrings("tlsFailure", sut.snapshot_publisher.last_error.?.sub_code.?);
    }
}

test "worker preserves loop progress and rejects stale preparation results" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Stage = enum { dns, socket };
    const Ending = enum { stop, shutdown, replace, replace_failed, queued_stop, preparation_failed, network_changed, better_path };
    const Probe = struct {
        stage: Stage,
        fail_first: bool,
        daemon: *Daemon = undefined,
        allocator: std.mem.Allocator = undefined,
        source_endpoints: ?[]api.ExtendedEndpoint = null,
        tun_fd: io.FileDescriptor,
        link_fd: io.FileDescriptor,
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        dns_calls: std.atomic.Value(usize) = .init(0),
        socket_calls: std.atomic.Value(usize) = .init(0),
        cleaned: std.atomic.Value(usize) = .init(0),
        completions: std.atomic.Value(usize) = .init(0),
        ticks: std.atomic.Value(usize) = .init(0),
        reads: std.atomic.Value(usize) = .init(0),
        starts: usize = 0,
        preparation_status: api.ConnectionStatus = .disconnected,
        timer: io.Timer = .{},
        original_callback: ConnectionWorker.Callback = undefined,

        fn block(self: *@This()) void {
            std.debug.assert(!daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            self.entered.store(true, .release);
            while (!self.released.load(.acquire)) core.sleepMs(1);
        }
        fn map(raw: ?*anyopaque, allocator: std.mem.Allocator, address: []const u8, _: ?io.ReachabilityInfo, _: u32) net.DNSResolver.Error![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.dns_calls.fetchAdd(1, .acq_rel) == 0 and self.stage == .dns) self.block();
            // The source Connection may already have destroyed its endpoints.
            std.debug.assert(std.mem.eql(u8, address, "127.0.0.1"));
            return allocator.dupe(u8, address);
        }
        fn socket(raw: ?*anyopaque, _: std.mem.Allocator, _: ?api.ExtendedEndpoint, _: u16, _: ?io.ReachabilityInfo, _: c_int) net.SocketFactory.Error!io.LinkDescriptor {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const first = self.socket_calls.fetchAdd(1, .acq_rel) == 0;
            if (first and self.stage == .socket) self.block();
            if (first and self.fail_first) return error.LinkNotActive;
            return .{ .fd = self.link_fd, .io = .{ .mock = .{ .ptr = self, .vtable = &link_io } } };
        }
        fn endpoints(raw: *anyopaque) ?[]const api.ExtendedEndpoint {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.source_endpoints;
        }
        fn create(raw: ?*anyopaque, allocator: std.mem.Allocator, _: net.ConnectionModule, _: net.Sandbox) net.ConnectionCreateError!net.Connection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const list = try allocator.alloc(api.ExtendedEndpoint, 2);
            errdefer allocator.free(list);
            list[0] = try api.ExtendedEndpoint.init("127.0.0.1", .init(.udp, 1194)).?.clone(allocator);
            errdefer list[0].deinit(allocator);
            list[1] = try api.ExtendedEndpoint.init("127.0.0.1", .init(.udp, 1195)).?.clone(allocator);
            self.source_endpoints = list;
            self.allocator = allocator;
            return .{ .ptr = self, .vtable = &connection_vtable, .daemon_io = .looper };
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            core.util.freeSlice(api.ExtendedEndpoint, self.allocator, self.source_endpoints.?);
            self.source_endpoints = null;
        }
        fn start(raw: *anyopaque, remote: net.RemoteDescriptor) net.ConnectionStartError!net.Connection.StartResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(daemon.testing.isCurrentThread(self.daemon.implementation.connection));
            // The invalidated request consumed endpoint 1194 on the same worker.
            std.debug.assert(remote.endpoint.?.address.port == 1195);
            self.starts += 1;
            return .started;
        }
        fn tick(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.ticks.fetchAdd(1, .release);
        }
        fn read(raw: *anyopaque, data: []u8) io.Error!?usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const count = std.c.read(self.tun_fd, data.ptr, data.len);
            if (count < 0) return error.WouldBlock;
            return @intCast(count);
        }
        fn readPackets(raw: ?*anyopaque, packets: io.Packets, _: ?[]const io.SocketAddress) anyerror!io.ReadAction {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.reads.fetchAdd(packets.len, .release);
            return .pause;
        }
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.cleaned.fetchAdd(1, .release);
        }
        fn noCleanup(_: *anyopaque) void {}
        fn noRead(_: *anyopaque, _: []u8) io.Error!?usize {
            return error.WouldBlock;
        }
        fn write(_: *anyopaque, data: []const u8, offset: usize) io.Error!usize {
            return data.len - offset;
        }
        fn mask(_: *anyopaque, _: bool, _: bool) io.Error!void {}
        fn reset(_: *anyopaque) io.Error!void {}
        fn code(_: *anyopaque) c_int {
            return 0;
        }
        const tun_io = source.net_io_posix.POSIXInterface.Mock.VTable{
            .set_event_mask = mask,
            .reset_events = reset,
            .read = read,
            .write = write,
            .cleanup = noCleanup,
            .last_error_code = code,
        };
        const link_io = blk: {
            var table = tun_io;
            table.read = noRead;
            table.cleanup = cleanup;
            break :blk table;
        };
        const connection_vtable = blk: {
            var table = FailingStartConnection.vtable;
            table.endpoints = endpoints;
            table.start = start;
            table.destroy = destroy;
            break :blk table;
        };
        const implementation = net.ConnectionImplementation.VTable{
            .module_type = FailingStartConnection.moduleType,
            .create_connection = create,
        };
        // Observe accepted completions, then forward to the daemon's callback.
        fn completed(raw: *anyopaque, context: *anyopaque, completion: ConnectionWorker.Completion) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.original_callback.call(self.original_callback.context, context, completion);
            _ = self.completions.fetchAdd(1, .release);
        }
    };
    for ([_]Stage{ .dns, .socket }) |stage| {
        for ([_]Ending{ .stop, .shutdown, .replace, .replace_failed, .queued_stop, .preparation_failed, .network_changed, .better_path }) |ending| {
            var tun_fds: [2]std.c.fd_t = undefined;
            var link_fds: [2]std.c.fd_t = undefined;
            try std.testing.expectEqual(0, std.c.pipe(&tun_fds));
            defer _ = std.c.close(tun_fds[0]);
            defer _ = std.c.close(tun_fds[1]);
            try std.testing.expectEqual(0, std.c.pipe(&link_fds));
            defer _ = std.c.close(link_fds[0]);
            defer _ = std.c.close(link_fds[1]);
            const flags = std.c.fcntl(tun_fds[0], std.c.F.GETFL, @as(c_int, 0));
            try std.testing.expect(std.c.fcntl(tun_fds[0], std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) >= 0);
            var probe = Probe{ .stage = stage, .fail_first = ending == .replace_failed or ending == .preparation_failed, .tun_fd = tun_fds[0], .link_fd = link_fds[0] };
            const allocator = std.testing.allocator;
            var registry = try net.ConnectionRegistry.init(allocator, &.{.{ .ptr = &probe, .vtable = &Probe.implementation }});
            defer registry.deinit(allocator);
            var profile = try api.Profile.parse(allocator, mock_mod.connectionProfileJson());
            defer profile.deinit(allocator);
            var controller = mock_mod.MockTunnelController{};
            var monitor = mock_mod.MockNetworkMonitor{ .reachable = false };
            var factory_table = mock_mod.noopSocketFactory().vtable.*;
            factory_table.create = Probe.socket;
            var resolver = mock_mod.noopDNSResolver();
            resolver.ptr = &probe;
            resolver.resolve_address_block = Probe.map;
            const sut = try Daemon.create(allocator, &profile, .{
                .objects = .{ .registry = &registry, .controller = controller.interface(), .resolver = resolver, .factory = .{ .ptr = &probe, .vtable = &factory_table }, .monitor = monitor.interface() },
                .options = .{ .reconnection_delay_ms = 60_000, .connection_options = .{ .connect_udp = true } },
            });
            defer sut.destroy();
            // Release blocked work on every error path before destroy joins it.
            defer probe.released.store(true, .release);
            defer sut.stop();
            probe.daemon = sut;
            try sut.start();
            const owner = sut.implementation.connection;
            const worker = owner.worker.?;
            probe.original_callback = worker.callback;
            worker.callback = .{ .context = &probe, .call = Probe.completed };
            // Publish callback configuration before submitting the first work item.
            monitor.reachable = true;
            try daemon.testing.evaluateConnection(owner);
            const deadline = core.monotonicNs() + 5 * std.time.ns_per_s;
            while (!probe.entered.load(.acquire)) {
                if (core.monotonicNs() >= deadline) return error.Timeout;
                core.sleepMs(1);
            }
            try daemon.testing.onLoop(owner, &probe, struct {
                fn run(loop: anytype, state: *Probe) daemon.Error!void {
                    state.preparation_status = state.daemon.snapshot_publisher.environment.connection_status;
                    std.debug.assert(!loop.looper.isLinkAttached());
                    loop.looper.attach(.{
                        .pair = .{ .tun = .{ .fd = state.tun_fd, .io = .{ .mock = .{ .ptr = state, .vtable = &Probe.tun_io } } } },
                        .on_read = .{ .context = state, .callback = Probe.readPackets },
                    }) catch return error.LooperFailure;
                    loop.looper.scheduleTimer(&state.timer, 1, .{ .context = state, .callback = Probe.tick }) catch return error.LooperFailure;
                }
            }.run);
            try std.testing.expectEqual(api.ConnectionStatus.connecting, probe.preparation_status);
            try std.testing.expectEqual(@as(isize, 1), std.c.write(tun_fds[1], "x", 1));
            while (probe.ticks.load(.acquire) == 0 or probe.reads.load(.acquire) == 0) {
                if (core.monotonicNs() >= deadline) return error.Timeout;
                core.sleepMs(1);
            }
            switch (ending) {
                .network_changed => try daemon.testing.perform(owner, .{ .onReachability = .{ .reachable = true } }),
                .better_path => try daemon.testing.perform(owner, .onBetterPath),
                .preparation_failed => {},
                .stop => sut.stop(),
                .shutdown => {
                    daemon.testing.shutdown(owner);
                    try waitForExit(owner);
                },
                .replace, .replace_failed, .queued_stop => {
                    try daemon.testing.perform(owner, .{ .onConnectionEvent = .{ .failed = .{
                        .err_pair = .{ .code = .ioFailure },
                        .disposition = .reconnect,
                    } } });
                    try daemon.testing.evaluateConnection(owner);
                    if (ending == .queued_stop) sut.stop();
                },
            }
            probe.released.store(true, .release);
            const replace = ending == .replace or ending == .replace_failed or ending == .network_changed or ending == .better_path;
            const expected_completions: usize = if (replace or ending == .queued_stop) 2 else 1;
            while (probe.completions.load(.acquire) < expected_completions) {
                if (core.monotonicNs() >= deadline) return error.Timeout;
                core.sleepMs(1);
            }
            if (ending != .shutdown) try waitForConnectionRequest(owner);
            try std.testing.expectEqual(@as(usize, if (replace) 1 else 0), probe.starts);
            if (ending == .preparation_failed) {
                try std.testing.expectEqual(api.ConnectionStatus.disconnected, sut.snapshot_publisher.environment.connection_status);
                try std.testing.expectEqual(daemon.testing.codeForDaemonStartError(error.UnableToStart), sut.snapshot_publisher.last_error.?.code);
                sut.stop();
            }
            if (replace) {
                // A stale failure must not overwrite the new attempt's state.
                try std.testing.expect(sut.snapshot_publisher.last_error == null);
                sut.stop();
            }
            const created = probe.socket_calls.load(.acquire);
            try std.testing.expectEqual(created - @as(usize, if (probe.fail_first) 1 else 0), probe.cleaned.load(.acquire));
            try std.testing.expect(probe.source_endpoints == null);
        }
    }
}

test "connection worker rolls back endpoint and thread allocations" {
    const Fixture = struct {
        const endpoints = [_]api.ExtendedEndpoint{
            api.ExtendedEndpoint.init("192.0.2.1", .init(.udp, 1194)).?,
            api.ExtendedEndpoint.init("192.0.2.2", .init(.udp, 1194)).?,
        };
        fn completed(_: *anyopaque, _: *anyopaque, _: ConnectionWorker.Completion) void {
            unreachable;
        }
        fn run(allocator: std.mem.Allocator) !void {
            var context: u8 = 0;
            const worker = try ConnectionWorker.create(
                allocator,
                mock_mod.noopDNSResolver(),
                mock_mod.noopSocketFactory(),
                &endpoints,
                .{ .context = &context, .call = completed },
            );
            defer worker.destroy();
            worker.close();
            try std.testing.expectError(error.Closed, worker.submit(.{
                .request_id = 1,
                .action = .start,
                .local_port = 0,
                .reachability = null,
                .connect_udp = true,
                .dns_timeout = 1,
                .link_activity_timeout = 1,
            }, &context));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}
