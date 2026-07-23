// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const daemon = @import("source").net_daemon;
const daemon_helpers = @import("source").net_daemon_helpers;
const net = @import("source").net;
const mock_mod = @import("source").mock;

const api = core.api;

const Daemon = daemon.Daemon;
const ConnectionGate = daemon_helpers.ConnectionGate;
const SnapshotPublisher = daemon_helpers.SnapshotPublisher;

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

const ReadyRecorder = struct {
    calls: usize = 0,

    fn notify(ptr: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
    }
};

test "connection gate notifies when enabled reachable status becomes ready" {
    const mock = mock_mod;
    var monitor = mock.MockNetworkMonitor{};
    var gate = ConnectionGate.init(reachabilityBlock(&monitor));
    var recorder = ReadyRecorder{};
    gate.setReadyHandler(.{
        .ptr = &recorder,
        .notify = ReadyRecorder.notify,
    });
    gate.startObserving();
    defer gate.stopObserving();

    try std.testing.expect(!gate.isReady());
    try std.testing.expect(gate.setEnabled(true));
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(!gate.updateStatus(.connecting));
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(gate.updateStatus(.disconnected));
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
}

test "connection gate waits for enable after cached reachable disconnected state" {
    const mock = mock_mod;
    var monitor = mock.MockNetworkMonitor{ .reachable = false };
    var gate = ConnectionGate.init(reachabilityBlock(&monitor));
    var recorder = ReadyRecorder{};
    gate.setReadyHandler(.{
        .ptr = &recorder,
        .notify = ReadyRecorder.notify,
    });
    gate.startObserving();
    defer gate.stopObserving();

    try std.testing.expect(!gate.setEnabled(true));
    monitor.setReachable(true);
    try std.testing.expect(gate.updateReachability(true));
    try std.testing.expect(gate.isReady());
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);

    try std.testing.expect(!gate.setEnabled(false));
    monitor.setReachable(false);
    try std.testing.expect(!gate.updateReachability(false));
    monitor.setReachable(true);
    try std.testing.expect(!gate.updateReachability(true));
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(gate.setEnabled(true));
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
}

test "snapshot publisher force-publishes status and last error snapshots" {
    var recorder = SnapshotRecorder{};
    var publisher = SnapshotPublisher.init((api.Profile{}).id, SnapshotRecorder.reportSnapshot, &recorder, 100);

    publisher.setConnectionStatus(.connecting);
    publisher.publishCurrentSnapshot(true);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(api.TunnelStatus.activating, recorder.last_snapshot.status);
    try std.testing.expectEqual(api.ConnectionStatus.connecting, recorder.last_snapshot.environment.?.connection_status);

    publisher.setLastError(.authentication);
    publisher.publishCurrentSnapshot(true);
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqualStrings("authentication", recorder.last_snapshot.environment.?.last_error_code.?);
}

test "snapshot publisher filters data-count-only snapshots by minimum delta" {
    var recorder = SnapshotRecorder{};
    var publisher = SnapshotPublisher.init((api.Profile{}).id, SnapshotRecorder.reportSnapshot, &recorder, 10);

    publisher.setConnectionStatus(.connected);
    publisher.setDataCount(.{ .received = 100, .sent = 100 });
    publisher.publishCurrentSnapshot(false);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(api.TunnelStatus.active, recorder.last_snapshot.status);

    publisher.setDataCount(.{ .received = 105, .sent = 104 });
    publisher.publishCurrentSnapshot(false);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);

    publisher.setDataCount(.{ .received = 106, .sent = 104 });
    publisher.publishCurrentSnapshot(false);
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqual(@as(u64, 106), recorder.last_snapshot.environment.?.data_count.received);
    try std.testing.expectEqual(@as(u64, 104), recorder.last_snapshot.environment.?.data_count.sent);

    publisher.setConnectionStatus(.connecting);
    publisher.setDataCount(.{ .received = 107, .sent = 104 });
    publisher.publishCurrentSnapshot(false);
    try std.testing.expectEqual(@as(usize, 3), recorder.count);
    try std.testing.expectEqual(api.TunnelStatus.activating, recorder.last_snapshot.status);
}

const SnapshotRecorder = struct {
    count: usize = 0,
    last_snapshot: api.TunnelSnapshot = .{},

    fn reportSnapshot(ptr: *const anyopaque, snapshot: api.TunnelSnapshot) void {
        const self: *SnapshotRecorder = @ptrCast(@alignCast(@constCast(ptr)));
        self.count += 1;
        self.last_snapshot = snapshot;
    }
};

test "connection daemon starts settings-only profile" {
    const allocator = std.testing.allocator;
    const mock = mock_mod;

    var implementations = [_]net.ConnectionImplementation{mock.mockConnectionImplementation()};
    var registry = try net.ConnectionRegistry.init(allocator, &implementations);
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var events = mock.ConnectionEventRecorder{};
    var monitor = mock.MockNetworkMonitor{};
    var sut = try newDaemon(
        allocator,
        mock.dnsOnlyProfileJson(),
        &registry,
        &controller,
        &events,
        &monitor,
        .{},
    );
    defer sut.deinit(allocator);

    try sut.start(allocator);
    try std.testing.expect(sut.isSettingsOnly());
    try std.testing.expectEqual(@as(usize, 1), controller.set_tunnel_settings_count);

    sut.stop();
    try std.testing.expectEqual(@as(usize, 1), controller.clear_tunnel_settings_count);
}

test "connection daemon starts connection and publishes lifecycle status" {
    const allocator = std.testing.allocator;
    const mock = mock_mod;

    var implementations = [_]net.ConnectionImplementation{mock.mockConnectionImplementation()};
    var registry = try net.ConnectionRegistry.init(allocator, &implementations);
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var events = mock.ConnectionEventRecorder{};
    var monitor = mock.MockNetworkMonitor{};
    var sut = try newDaemon(
        allocator,
        mock.connectionProfileJson(),
        &registry,
        &controller,
        &events,
        &monitor,
        .{ .stop_delay_ms = 100 },
    );
    defer sut.deinit(allocator);

    try sut.start(allocator);
    try std.testing.expect(sut.isConnectionProfile());
    try std.testing.expectEqualSlices(api.ConnectionStatus, &.{
        .disconnected,
        .connecting,
        .connected,
    }, sut.testStatuses());
    try std.testing.expectEqual(@as(usize, 4), events.remove_count);
    try std.testing.expectEqual(api.ConnectionStatus.connected, events.connection_status.?);
    try std.testing.expect(events.has_data_count);
    try std.testing.expectEqual(@as(u64, 10), events.data_count.received);
    try std.testing.expectEqual(@as(u64, 20), events.data_count.sent);
    try std.testing.expectEqual(api.PartoutErrorCode.authentication, events.last_error_code.?);
    try std.testing.expectEqual(@as(usize, 1), monitor.start_count);

    sut.stop();
    try std.testing.expectEqualSlices(api.ConnectionStatus, &.{
        .disconnected,
        .connecting,
        .connected,
        .disconnecting,
        .disconnected,
    }, sut.testStatuses());
    try std.testing.expectEqual(@as(usize, 1), monitor.stop_count);
    try std.testing.expectEqual(@as(usize, 7), events.remove_count);
    try std.testing.expect(events.connection_status == null);
    try std.testing.expect(!events.has_data_count);
    try std.testing.expect(events.last_error_code == null);
}

test "connection daemon passes connection options into sandbox" {
    const allocator = std.testing.allocator;
    const mock = mock_mod;

    var capture = SandboxCapture{};
    var implementations = [_]net.ConnectionImplementation{capture.implementation()};
    var registry = try net.ConnectionRegistry.init(allocator, &implementations);
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var events = mock.ConnectionEventRecorder{};
    var monitor = mock.MockNetworkMonitor{};
    var sut = try newDaemon(
        allocator,
        mock.connectionProfileJson(),
        &registry,
        &controller,
        &events,
        &monitor,
        .{ .connection_options = .{
            .dns_timeout = 1234,
            .link_activity_timeout = 2345,
            .link_write_timeout = 3456,
            .min_data_count_interval = 4567,
            .user_info = .{ .bytes = "{\"source\":\"test\"}" },
        } },
    );
    defer sut.deinit(allocator);

    const options = capture.options orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1234), options.dns_timeout);
    try std.testing.expectEqual(@as(u32, 2345), options.link_activity_timeout);
    try std.testing.expectEqual(@as(u32, 3456), options.link_write_timeout);
    try std.testing.expectEqual(@as(u32, 4567), options.min_data_count_interval);
    try std.testing.expectEqualStrings("{\"source\":\"test\"}", options.user_info.?.bytes);
}

test "connection daemon connects when previously unreachable network becomes reachable" {
    const allocator = std.testing.allocator;
    const mock = mock_mod;

    var implementations = [_]net.ConnectionImplementation{mock.mockConnectionImplementation()};
    var registry = try net.ConnectionRegistry.init(allocator, &implementations);
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var events = mock.ConnectionEventRecorder{};
    var monitor = mock.MockNetworkMonitor{ .reachable = false };
    var sut = try newDaemon(
        allocator,
        mock.connectionProfileJson(),
        &registry,
        &controller,
        &events,
        &monitor,
        .{},
    );
    defer sut.deinit(allocator);

    try sut.start(allocator);
    defer sut.stop();
    try std.testing.expectEqualSlices(api.ConnectionStatus, &.{
        .disconnected,
    }, sut.testStatuses());

    monitor.setReachable(true);
    try std.testing.expectEqualSlices(api.ConnectionStatus, &.{
        .disconnected,
        .connecting,
        .connected,
    }, sut.testStatuses());
    try std.testing.expectEqual(api.ConnectionStatus.connected, events.connection_status.?);
}

test "connection daemon forwards better path events to current connection" {
    const allocator = std.testing.allocator;
    const mock = mock_mod;

    var blocking_connection = mock.BlockingStopConnection{};
    var implementations = [_]net.ConnectionImplementation{mock.blockingConnectionImplementation(&blocking_connection)};
    var registry = try net.ConnectionRegistry.init(allocator, &implementations);
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var events = mock.ConnectionEventRecorder{};
    var monitor = mock.MockNetworkMonitor{};
    var sut = try newDaemon(
        allocator,
        mock.connectionProfileJson(),
        &registry,
        &controller,
        &events,
        &monitor,
        .{},
    );
    defer sut.deinit(allocator);

    monitor.onBetterPath();
    try std.testing.expectEqual(@as(usize, 0), blocking_connection.better_path_count);

    try sut.start(allocator);
    monitor.onBetterPath();
    try std.testing.expectEqual(@as(usize, 1), blocking_connection.better_path_count);

    sut.stop();

    monitor.onBetterPath();
    try std.testing.expectEqual(@as(usize, 1), blocking_connection.better_path_count);
}

test "connection daemon runs delayed connection work on its actor" {
    const allocator = std.testing.allocator;
    const mock = mock_mod;

    var delayed_connection = DelayedConnection{};
    var implementations = [_]net.ConnectionImplementation{delayed_connection.implementation()};
    var registry = try net.ConnectionRegistry.init(allocator, &implementations);
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var events = mock.ConnectionEventRecorder{};
    var monitor = mock.MockNetworkMonitor{};
    var sut = try newDaemon(
        allocator,
        mock.connectionProfileJson(),
        &registry,
        &controller,
        &events,
        &monitor,
        .{},
    );
    defer sut.deinit(allocator);

    try sut.start(allocator);
    while (!delayed_connection.did_run.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    try std.testing.expect(delayed_connection.ran_on_start_thread);
    try std.testing.expect(delayed_connection.ran_off_timer_thread);
    sut.stop();
}

test "connection daemon drains an overlapping timer callback and drops stale work" {
    const allocator = std.testing.allocator;
    const mock = mock_mod;

    var delayed_connection = DelayedConnection{ .pause_timer_before_enqueue = true };
    var implementations = [_]net.ConnectionImplementation{delayed_connection.implementation()};
    var registry = try net.ConnectionRegistry.init(allocator, &implementations);
    defer registry.deinit(allocator);
    var controller = mock.MockTunnelController{};
    var events = mock.ConnectionEventRecorder{};
    var monitor = mock.MockNetworkMonitor{};
    var sut = try newDaemon(
        allocator,
        mock.connectionProfileJson(),
        &registry,
        &controller,
        &events,
        &monitor,
        .{},
    );
    defer sut.deinit(allocator);
    defer sut.stop();
    defer delayed_connection.allow_timer_enqueue.store(true, .release);

    try sut.start(allocator);
    while (!delayed_connection.timer_started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    var stop_thread = try std.Thread.spawn(.{}, stopDaemon, .{sut});
    while (!delayed_connection.stop_entered.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    delayed_connection.allow_timer_enqueue.store(true, .release);
    stop_thread.join();

    // Flush the actor queue. The timer posted while the first stop owned the
    // actor, so its serialized block must have been queued before this call.
    sut.stop();
    try std.testing.expectEqual(@as(usize, 0), delayed_connection.serialized_count);
}

fn stopDaemon(sut: *Daemon) void {
    sut.stop();
}

const DelayedConnection = struct {
    timer: core.RunAfter = .{},
    serialized_executor: net.SerializedExecutor = .{},
    start_thread: ?std.Thread.Id = null,
    timer_thread: ?std.Thread.Id = null,
    ran_on_start_thread: bool = false,
    ran_off_timer_thread: bool = false,
    did_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pause_timer_before_enqueue: bool = false,
    timer_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allow_timer_enqueue: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    serialized_count: usize = 0,

    fn implementation(self: *DelayedConnection) net.ConnectionImplementation {
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
        sandbox: net.Sandbox,
    ) net.ConnectionCreateError!net.Connection {
        const self: *DelayedConnection = @ptrCast(@alignCast(ptr.?));
        self.serialized_executor = sandbox.serialized_executor;
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn start(ptr: *anyopaque, events: net.Connection.Events) net.ConnectionStartError!bool {
        const self: *DelayedConnection = @ptrCast(@alignCast(ptr));
        self.start_thread = std.Thread.getCurrentId();
        events.status(events.ctx, .connecting);
        self.timer.init(1, onTimer, self) catch return error.UnableToStart;
        events.status(events.ctx, .connected);
        return true;
    }

    fn onTimer(ctx: ?*anyopaque) void {
        const self: *DelayedConnection = @ptrCast(@alignCast(ctx.?));
        self.timer_thread = std.Thread.getCurrentId();
        self.timer_started.store(true, .release);
        while (self.pause_timer_before_enqueue and !self.allow_timer_enqueue.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        self.serialized_executor.run(self, onSerialized);
    }

    fn onSerialized(ctx: *anyopaque) void {
        const self: *DelayedConnection = @ptrCast(@alignCast(ctx));
        const current = std.Thread.getCurrentId();
        self.serialized_count += 1;
        self.ran_on_start_thread = current == self.start_thread.?;
        self.ran_off_timer_thread = current != self.timer_thread.?;
        self.did_run.store(true, .release);
    }

    fn stop(ptr: *anyopaque, _: u32, events: net.Connection.Events) void {
        const self: *DelayedConnection = @ptrCast(@alignCast(ptr));
        self.stop_entered.store(true, .release);
        self.timer.cancel();
        self.timer.wait();
        events.status(events.ctx, .disconnecting);
        events.status(events.ctx, .disconnected);
    }

    fn networkChange(_: *anyopaque, _: net.ReachabilityInfo, _: net.Connection.Events) void {}

    fn betterPath(_: *anyopaque, _: net.Connection.Events) void {}

    fn deinit(ptr: *anyopaque, _: std.mem.Allocator) void {
        const self: *DelayedConnection = @ptrCast(@alignCast(ptr));
        self.timer.deinit();
    }

    const vtable = net.Connection.VTable{
        .start = start,
        .stop = stop,
        .network_change = networkChange,
        .better_path = betterPath,
        .deinit = deinit,
    };

    const implementation_vtable = net.ConnectionImplementation.VTable{
        .module_type = moduleType,
        .create_connection = create,
    };
};

const SandboxCapture = struct {
    options: ?net.ConnectionOptions = null,

    fn implementation(self: *SandboxCapture) net.ConnectionImplementation {
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
        sandbox: net.Sandbox,
    ) net.ConnectionCreateError!net.Connection {
        const self: *SandboxCapture = @ptrCast(@alignCast(ptr.?));
        self.options = sandbox.options;
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn start(_: *anyopaque, _: net.Connection.Events) net.ConnectionStartError!bool {
        return false;
    }

    fn stop(_: *anyopaque, _: u32, _: net.Connection.Events) void {}

    fn networkChange(_: *anyopaque, _: net.ReachabilityInfo, _: net.Connection.Events) void {}

    fn betterPath(_: *anyopaque, _: net.Connection.Events) void {}

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

    const vtable = net.Connection.VTable{
        .start = start,
        .stop = stop,
        .network_change = networkChange,
        .better_path = betterPath,
        .deinit = deinit,
    };

    const implementation_vtable = net.ConnectionImplementation.VTable{
        .module_type = moduleType,
        .create_connection = create,
    };
};

fn newDaemon(
    allocator: std.mem.Allocator,
    profile_json: []const u8,
    registry: *const net.ConnectionRegistry,
    controller: *mock_mod.MockTunnelController,
    events: *mock_mod.ConnectionEventRecorder,
    monitor: *mock_mod.MockNetworkMonitor,
    options: daemon.Context.Options,
) !*Daemon {
    var profile = try api.Profile.parse(allocator, profile_json);
    defer profile.deinit(allocator);
    return try Daemon.create(allocator, &profile, .{
        .objects = .{
            .registry = registry,
            .controller = controller.interface(),
            .resolver = mock_mod.noopDNSResolver(),
            .factory = mock_mod.noopSocketFactory(),
            .monitor = monitor.interface(),
        },
        .options = withEvents(options, events),
    });
}

fn withEvents(
    options: daemon.Context.Options,
    events: *mock_mod.ConnectionEventRecorder,
) daemon.Context.Options {
    var updated = options;
    updated.events = events.events();
    return updated;
}
