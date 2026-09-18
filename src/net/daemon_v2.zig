// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Daemon owns the shared profile, lifecycle state, controller, and reporting.
//! Its private SettingsDaemon and ConnectionDaemon implementations borrow it
//! and supply the behavior for each profile type.
//!
//! SettingsDaemon is synchronous; callers serialize its controls. ConnectionDaemon
//! owns an actor that serializes connection work and updates to shared state.
//! Connection and I/O callbacks run on the looper and enqueue actor messages.
//! Ordinary reconnects retain Connection; terminal looper recovery replaces it.
//! Stop before destroy; monitors must cease callbacks after setEventHandler(null).

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const conn_mod = @import("connection.zig");
const helpers = @import("daemon_helpers.zig");
const io = @import("io.zig");
const looper_mod = @import("looper.zig");
const sandbox = @import("sandbox.zig");

const api = core.api;
const log = core.logging;
const Connection = conn_mod.Connection;
const ConnectionGate = helpers.ConnectionGate;
const ConnectionRegistry = conn_mod.ConnectionRegistry;
const EndpointResolver = net.EndpointResolver;
const Looper = looper_mod.Looper;
const SnapshotPublisher = helpers.SnapshotPublisher;
const activeConnectionModule = conn_mod.activeConnectionModule;

pub const Error = api.DecodeError || conn_mod.CreateError || error{
    AlreadyStarted,
    Closed,
    InvalidProfile,
    LooperFailure,
};

const StartError = Error || conn_mod.StartError ||
    sandbox.TunnelController.Error;

pub const EventKey = enum {
    connection_status,
    data_count,
    last_error_code,
};

pub const Events = struct {
    ctx: *anyopaque,
    status: *const fn (*anyopaque, api.ConnectionStatus) void,
    last_error: *const fn (*anyopaque, api.PartoutErrorCode) void,
    data_count: *const fn (*anyopaque, api.DataCount) void,
    remove_key: *const fn (*anyopaque, EventKey) void,
};

pub const Context = struct {
    pub const Objects = struct {
        registry: *const ConnectionRegistry,
        controller: sandbox.TunnelController,
        resolver: sandbox.DNSResolver,
        factory: sandbox.SocketFactory,
        monitor: sandbox.NetworkMonitor,
    };

    pub const Options = struct {
        starts_immediately: bool = false,
        cancels_unrecoverable: bool = true,
        stop_delay_ms: u32 = 2000,
        reconnection_delay_ms: u32 = 2000,
        min_data_count_delta: u64 = 0,
        events: ?Events = null,
        cache_dir: []const u8 = "",
        connection_options: sandbox.ConnectionOptions = .{},
    };

    objects: Objects,
    options: Options,
};

pub const Daemon = struct {
    const State = enum { initial, started, failed, stopping, stopped };
    const StopMode = enum { clear_environment, preserve_environment };

    allocator: std.mem.Allocator,
    profile: api.Profile,
    controller: sandbox.TunnelController,
    options: Context.Options,
    state: State = .initial,
    stop_mode: StopMode = .clear_environment,
    snapshot_publisher: SnapshotPublisher,
    cancellation_requested: bool = false,

    implementation: union(enum) {
        settings: *SettingsDaemon,
        connection: *ConnectionDaemon,
    },

    // Testing only
    test_status_history: [64]api.ConnectionStatus = undefined,
    test_status_count: usize = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        original_profile: *const api.Profile,
        context: Context,
    ) Error!*Daemon {
        log.write(.notice, "Using v2 daemon");
        var profile = try original_profile.clone(allocator);
        errdefer profile.deinit(allocator);
        log.write(.notice, "Decoded profile:");
        log.writeProfile(.notice, &profile);

        const self = try allocator.create(Daemon);
        errdefer allocator.destroy(self);
        const snapshot_publisher = SnapshotPublisher.init(
            profile.id,
            reportSnapshot,
            self,
            context.options.min_data_count_delta,
        );
        self.* = .{
            .allocator = allocator,
            .profile = profile,
            .controller = context.objects.controller,
            .options = context.options,
            .snapshot_publisher = snapshot_publisher,
            .implementation = undefined,
        };
        // Both implementations borrow this shared state at its final address.
        self.implementation = if (activeConnectionModule(&self.profile) != null)
            .{ .connection = try ConnectionDaemon.create(self, context.objects) }
        else
            .{ .settings = try SettingsDaemon.create(self) };
        return self;
    }

    pub fn destroy(self: *Daemon) void {
        log.write(.debug, "Deinit v2 daemon");
        if (self.state != .initial and self.state != .stopped)
            @panic("Daemon.destroy() requires an initial or fully stopped daemon");
        switch (self.implementation) {
            .settings => |settings| settings.destroy(),
            .connection => |connection| connection.destroy(),
        }
        self.profile.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn isConnectionProfile(self: Daemon) bool {
        return self.implementation == .connection;
    }

    pub fn isSettingsOnly(self: Daemon) bool {
        return self.implementation == .settings;
    }

    pub fn start(self: *const Daemon) Error!void {
        return switch (self.implementation) {
            .settings => |settings| settings.start(),
            .connection => |connection| connection.start(),
        };
    }

    pub fn hold(self: *const Daemon) void {
        switch (self.implementation) {
            .settings => |settings| settings.hold(),
            .connection => |connection| connection.hold(),
        }
    }

    pub fn stop(self: *const Daemon) void {
        switch (self.implementation) {
            .settings => |settings| settings.stop(),
            .connection => |connection| connection.stop(),
        }
    }

    pub fn testStatuses(self: *const Daemon) []const api.ConnectionStatus {
        return self.test_status_history[0..self.test_status_count];
    }

    fn handleStartError(self: *Daemon, err: StartError) api.PartoutErrorCode {
        const code = partoutCodeForDaemonStartError(err);
        self.handleLastError(code);
        self.controller.setReasserting(false);
        return code;
    }

    fn handleLastError(self: *Daemon, code: api.PartoutErrorCode) void {
        self.resetDataCount();
        self.snapshot_publisher.setLastError(code);
        self.snapshot_publisher.publishCurrentSnapshot(true);
        if (self.options.events) |e| e.last_error(e.ctx, code);
    }

    fn handleDataCount(self: *Daemon, data_count: api.DataCount) void {
        if (self.state != .started or self.snapshot_publisher.environment.connection_status != .connected) return;
        self.snapshot_publisher.setDataCount(data_count);
        self.snapshot_publisher.publishCurrentSnapshot(false);
        if (self.options.events) |e| e.data_count(e.ctx, data_count);
    }

    fn resetDataCount(self: *Daemon) void {
        self.snapshot_publisher.setDataCount(.{});
        self.emitRemove(.data_count);
    }

    fn emitStatus(self: *Daemon, status: api.ConnectionStatus) void {
        self.publishTestStatus(status);
        if (self.options.events) |e| e.status(e.ctx, status);
    }

    fn emitRemove(self: *const Daemon, key: EventKey) void {
        if (self.options.events) |e| e.remove_key(e.ctx, key);
    }

    fn clearEnvironment(self: *Daemon) void {
        log.write(.notice, "Clear connection events");
        self.snapshot_publisher.clearEnvironment();
        self.emitRemove(.connection_status);
        self.emitRemove(.data_count);
        self.emitRemove(.last_error_code);
    }

    fn reportSnapshot(ctx: ?*const anyopaque, snapshot: api.TunnelSnapshot) void {
        const self: *const Daemon = @ptrCast(@alignCast(ctx.?));
        self.controller.reportSnapshot(snapshot);
    }

    fn publishTestStatus(self: *Daemon, status: api.ConnectionStatus) void {
        if (self.test_status_count < self.test_status_history.len) {
            self.test_status_history[self.test_status_count] = status;
            self.test_status_count += 1;
        }
    }

    // ConnectionDaemon calls these on its actor; SettingsDaemon calls them
    // synchronously. Implementations own execution, while Daemon owns state.
    fn beginStart(self: *Daemon) Error!void {
        if (self.state != .initial) return error.AlreadyStarted;
        self.state = .started;
        log.write(.notice, "Start daemon");
        self.clearEnvironment();
    }

    fn beginStop(self: *Daemon, mode: StopMode) bool {
        switch (self.state) {
            .stopping => {
                // A reentrant hold may upgrade an in-progress normal stop.
                if (mode == .preserve_environment) self.stop_mode = mode;
                return false;
            },
            .stopped => return false,
            .initial, .started, .failed => {},
        }
        self.stop_mode = mode;
        self.state = .stopping;
        log.write(.notice, "Stop daemon");
        return true;
    }

    fn finishStop(self: *Daemon) void {
        self.state = .stopped;
        if (self.stop_mode == .clear_environment) self.clearEnvironment();
        log.write(.notice, "Daemon stopped successfully");
    }

    fn requestCancellation(self: *Daemon, code: ?api.PartoutErrorCode, force: bool) void {
        self.enterFailedState();
        if (self.cancellation_requested) return;
        if (!force and !self.options.cancels_unrecoverable) return;
        self.cancellation_requested = true;
        self.controller.cancelTunnelConnection(code);
    }

    fn enterFailedState(self: *Daemon) void {
        if (self.state != .started) return;
        self.state = .failed;
        switch (self.implementation) {
            .settings => {},
            .connection => |connection| connection.pause(),
        }
    }
};

// Synchronous settings-only behavior. Controls are serialized by the caller.
const SettingsDaemon = struct {
    daemon: *Daemon,

    fn create(daemon: *Daemon) Error!*SettingsDaemon {
        const self = try daemon.allocator.create(SettingsDaemon);
        self.* = .{ .daemon = daemon };
        return self;
    }

    fn destroy(self: *SettingsDaemon) void {
        self.daemon.allocator.destroy(self);
    }

    fn start(self: *SettingsDaemon) Error!void {
        const daemon = self.daemon;
        try daemon.beginStart();
        var maybe_info = buildSettingsOnlyTunnelInfo(daemon.allocator, &daemon.profile) catch |err| {
            log.writef(.fault, "Unable to build settings-only daemon: {s}", .{@errorName(err)});
            const code = daemon.handleStartError(err);
            daemon.requestCancellation(code, false);
            return;
        };
        if (maybe_info) |*info| {
            defer info.deinit(daemon.allocator);
            _ = daemon.controller.setTunnelSettings(info.*) catch |err| {
                log.writef(.fault, "Unable to set settings-only tunnel: {s}", .{@errorName(err)});
                const code = daemon.handleStartError(err);
                daemon.requestCancellation(code, false);
                return;
            };
        }
    }

    fn hold(self: *SettingsDaemon) void {
        self.doStop(.preserve_environment);
    }

    fn stop(self: *SettingsDaemon) void {
        self.doStop(.clear_environment);
    }

    fn doStop(self: *SettingsDaemon, mode: Daemon.StopMode) void {
        if (!self.daemon.beginStop(mode)) return;
        self.daemon.controller.clearTunnelSettings(false);
        self.daemon.finishStop();
    }

    fn buildSettingsOnlyTunnelInfo(
        allocator: std.mem.Allocator,
        profile: *const api.Profile,
    ) !?api.TunnelRemoteInfoWrapper {
        var original_module_id: ?api.UUID = null;
        for (profile.modules) |*module| {
            if (!api.isActiveProfileModule(profile, api.moduleId(module))) continue;
            if (api.typeBuildsConnection(api.moduleType(module))) continue;
            original_module_id = api.moduleId(module);
            break;
        }

        const info = api.TunnelRemoteInfoWrapper{
            .profile = profile.*,
            .original_module_id = original_module_id orelse return null,
            .requires_virtual_device = false,
        };
        return try info.clone(allocator);
    }
};

// Connection behavior and resources. Shared lifecycle and reporting live in Daemon;
// this actor serializes both its connection work and updates to that shared state.
const ConnectionDaemon = struct {
    // Shared lifecycle and reporting, plus connection-specific dependencies.
    daemon: *Daemon,
    module: conn_mod.ConnectionModule,
    registry: *const ConnectionRegistry,
    resolver: sandbox.DNSResolver,
    factory: sandbox.SocketFactory,
    monitor: sandbox.NetworkMonitor,

    // Internal state
    actor: *Actor,
    connection: ?Connection,
    // Valid while connection is non-null; only this class accesses them.
    endpoint_resolver: EndpointResolver,
    looper: *Looper,
    tunnel: ?net.TunWrapper,
    gate: ConnectionGate,
    resume_gate_timer: core.RunAfter,
    is_evaluating_connection: bool,
    is_deinitializing: bool,

    //#region Caller thread - daemon lifecycle

    // Called through Daemon by its owner. Construction and destruction bracket the
    // actor lifetime; start, hold, and stop synchronously forward to the actor.
    // If started, the caller must complete stop before destruction.

    fn create(daemon: *Daemon, objects: Context.Objects) Error!*ConnectionDaemon {
        const module = activeConnectionModule(&daemon.profile) orelse return error.InvalidProfile;
        log.write(.notice, "Create connection daemon");
        const allocator = daemon.allocator;
        const self = try allocator.create(ConnectionDaemon);
        errdefer allocator.destroy(self);
        const actor = Actor.create(allocator, self) catch return error.OutOfMemory;
        self.* = .{
            .daemon = daemon,
            .actor = actor,
            .module = module,
            .registry = objects.registry,
            .resolver = objects.resolver,
            .factory = objects.factory,
            .monitor = objects.monitor,
            .connection = null,
            .endpoint_resolver = undefined,
            .looper = undefined,
            .tunnel = null,
            .gate = ConnectionGate.init(null),
            .resume_gate_timer = .{},
            .is_evaluating_connection = false,
            .is_deinitializing = false,
        };
        return self;
    }

    fn destroy(self: *ConnectionDaemon) void {
        // Daemon checked the shared lifecycle precondition. Drain callbacks
        // before releasing this implementation and its borrowed Daemon.
        self.resume_gate_timer.deinit();

        // Suppress the actor's unexpected-termination path: stop() already
        // released the connection resources.
        self.is_deinitializing = true;
        self.actor.destroy();

        self.monitor.setEventHandler(null);
        self.monitor.stopObserving();
        self.gate.stopObserving();
        self.gate.deinit();
        if (self.connection != null)
            @panic("ConnectionDaemon.destroy() cannot release live connection resources");
        self.daemon.allocator.destroy(self);

        log.write(.debug, "Deinit daemon");
    }

    fn start(self: *const ConnectionDaemon) Error!void {
        return self.actor.perform(void, .start);
    }

    fn hold(self: *const ConnectionDaemon) void {
        self.actor.perform(void, .hold) catch return;
    }

    fn stop(self: *const ConnectionDaemon) void {
        self.actor.perform(void, .stop) catch return;
    }

    //#endregion

    //#region Any thread - asynchronous events

    // Network and protocol producers may hold locks needed by actor work. These
    // callbacks enqueue messages without waiting or changing daemon state; borrowed
    // establishment data is cloned. V2 protocol events normally arrive on the looper.

    // This is where connection events are rerouted through the actor
    fn events(self: *ConnectionDaemon) Connection.Events {
        return .{
            .ctx = self,
            .established = onConnectionEstablished,
            .failed = onConnectionFailed,
            .stopped = onConnectionStopped,
            .set_env = onConnectionSetEnvironmentValue,
            .data_count = onConnectionDataCount,
            // Deprecated callbacks must never be emitted by a v2 connection.
            .status = legacyStatus,
            .last_error = legacyLastError,
            .cancel = legacyCancel,
        };
    }

    fn onConnectionEstablished(
        ctx: *anyopaque,
        success: net.Connection.Events.Success,
    ) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        // The payload is borrowed only for this callback. Own it across the
        // asynchronous hop, including when stop overtakes its actor handler.
        const endpoint = success.remote_endpoint.clone(self.daemon.allocator) catch {
            onConnectionFailed(ctx, .{ .code = .outOfMemory, .disposition = .reconnect });
            return;
        };
        var info = success.info.clone(self.daemon.allocator) catch {
            endpoint.deinit(self.daemon.allocator);
            onConnectionFailed(ctx, .{ .code = .outOfMemory, .disposition = .reconnect });
            return;
        };
        self.actor.schedule(.{ .onConnectionEstablished = .{
            .remote_endpoint = endpoint,
            .info = info,
        } }) catch |err| {
            endpoint.deinit(self.daemon.allocator);
            info.deinit(self.daemon.allocator);
            log.writef(.fault, "Unable to enqueue established connection: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionFailed(ctx: *anyopaque, failure: Connection.Events.Failure) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        self.actor.schedule(.{ .onConnectionFailed = failure }) catch |err| {
            log.writef(.err, "Unable to enqueue connection failure: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionStopped(ctx: *anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        self.actor.schedule(.onConnectionStopped) catch |err| {
            log.writef(.err, "Unable to enqueue connection stop: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionSetEnvironmentValue(ctx: *anyopaque, key: []const u8, value: ?[]const u8) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        // The producer releases this storage when the callback returns. Own both
        // strings until the actor delivers the update (or discards it after stop).
        const allocator = self.daemon.allocator;
        const owned_key = allocator.dupe(u8, key) catch {
            log.write(.err, "Unable to copy connection environment key");
            return;
        };
        const owned_value = if (value) |bytes| allocator.dupe(u8, bytes) catch {
            allocator.free(owned_key);
            log.write(.err, "Unable to copy connection environment value");
            return;
        } else null;
        self.actor.schedule(.{ .onConnectionSetEnvironmentValue = .{
            .key = owned_key,
            .value = owned_value,
        } }) catch |err| {
            allocator.free(owned_key);
            if (owned_value) |bytes| allocator.free(bytes);
            log.writef(.err, "Unable to enqueue connection environment update: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionDataCount(ctx: *anyopaque, data_count: api.DataCount) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        self.actor.schedule(.{ .onConnectionDataCount = data_count }) catch |err| {
            log.writef(.err, "Unable to report connection data count: {s}", .{@errorName(err)});
        };
    }

    fn legacyStatus(_: *anyopaque, _: api.ConnectionStatus) void {
        @panic("Unimplemented");
    }

    fn legacyLastError(_: *anyopaque, _: api.PartoutErrorCode) void {
        @panic("Unimplemented");
    }

    fn legacyCancel(_: *anyopaque, _: ?api.PartoutErrorCode) void {
        @panic("Unimplemented");
    }

    // Network callbacks may originate while the platform owns a lock that is
    // also needed by tunnel-controller callbacks. Never wait for the actor
    // here: starting a connection can synchronously report a snapshot back to
    // the platform and would otherwise deadlock with that lock held.
    fn onReachability(ctx: ?*anyopaque, reachability: io.ReachabilityInfo) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        self.actor.schedule(.{ .onReachability = reachability }) catch |err| {
            log.writef(.err, "Unable to enqueue reachability: {s}", .{@errorName(err)});
        };
    }

    // Like reachability, better-path notifications come from platform code
    // whose locks must be released before calling back into the controller.
    fn onBetterPath(ctx: ?*anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        self.actor.schedule(.onBetterPath) catch |err| {
            log.writef(.err, "Unable to enqueue better path: {s}", .{@errorName(err)});
        };
    }

    //#endregion

    //#region Timer thread - delayed gate resumption

    // RunAfter invokes this callback on its worker. It synchronously enters the
    // actor so gate changes remain serialized with connection work.

    // This is scheduled with a delay
    fn onResumeGate(ctx: ?*anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        self.actor.perform(void, .resumeGate) catch |err| {
            log.writef(.err, "Unable to resume connection gate: {s}", .{@errorName(err)});
        };
    }

    //#endregion

    //#region Actor thread - connection lifecycle and state

    // The actor serializes these methods and their updates to the shared Daemon.
    // Gate callbacks also run inline here. Protocol operations cross to the looper
    // through callOnLooper; only the actor waits for that work to finish.

    fn doStart(self: *ConnectionDaemon) Error!void {
        if (self.daemon.state != .initial) return error.AlreadyStarted;
        try self.createConnection();
        try self.daemon.beginStart();

        // Start .disconnected
        self.daemon.emitStatus(.disconnected);

        // Notify reachability to the connection gate
        self.monitor.setEventHandler(.{
            .ptr = self,
            .on_reachability = onReachability,
            .on_better_path = onBetterPath,
        });
        // Notify connection gate ready to the daemon
        self.gate.setReadyHandler(.{
            .ptr = self,
            .notify = onNetworkReady,
        });
        // Read current reachability
        self.gate.setReachabilityBlock(.{
            .ptr = self,
            .is_reachable = isReachable,
        });

        self.monitor.startObserving();
        self.gate.startObserving();
        _ = self.gate.updateStatus(.disconnected);
        log.write(.notice, "ConnectionDaemon started successfully");

        // Start a connection now, or defer the choice to the gate
        if (self.daemon.options.starts_immediately) {
            self.startConnection();
        } else {
            _ = self.gate.setEnabled(true);
        }
    }

    fn doHold(self: *ConnectionDaemon) void {
        self.doStop(.preserve_environment);
    }

    fn doStop(self: *ConnectionDaemon, mode: Daemon.StopMode) void {
        if (!self.daemon.beginStop(mode)) return;
        self.resume_gate_timer.cancel();

        self.monitor.setEventHandler(null);
        self.monitor.stopObserving();

        self.gate.setReachabilityBlock(null);
        self.gate.stopObserving();

        // Finalize the connection before releasing its resources.
        log.writef(.notice, "Connection profile, disconnect with a timeout of {} milliseconds", .{
            self.daemon.options.stop_delay_ms,
        });
        if (self.connection == null) {
            self.daemon.finishStop();
            return;
        }
        self.trackConnectionStatus(.disconnecting);
        self.stopConnection(self.daemon.options.stop_delay_ms, .explicit_stop) catch |err| {
            log.writef(.err, "Unable to stop connection: {s}", .{@errorName(err)});
        };
        self.trackConnectionStatus(.disconnected);
        self.releaseConnection();
        self.daemon.controller.clearTunnelSettings(false);
        self.daemon.finishStop();
    }

    // Called on the actor, before accepting connection work. Publish the
    // complete state before starting callbacks on the looper.
    fn createConnection(self: *ConnectionDaemon) Error!void {
        std.debug.assert(self.connection == null);
        const connection = try self.registry.createConnection(self.daemon.allocator, self.module, .{
            .profile = &self.daemon.profile,
            .options = self.daemon.options.connection_options,
            .cache_dir = self.daemon.options.cache_dir,
            .events = self.events(),
            // FIXME: ###, Delete all these from Sandbox
            .controller = self.daemon.controller,
            .resolver = self.resolver,
            .factory = self.factory,
            .looper = undefined,
            .serialized_executor = undefined,
        });
        errdefer connection.destroy();
        const looper = try self.daemon.allocator.create(Looper);
        errdefer self.daemon.allocator.destroy(looper);
        looper.* = Looper.init(self.daemon.allocator, .{
            .on_finish = .{ .context = self, .callback = onLooperTerminate },
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.MuxFailure => error.LooperFailure,
        };
        errdefer looper.deinit();
        self.connection = connection;
        errdefer self.connection = null;
        self.endpoint_resolver = EndpointResolver.init(self.daemon.allocator, connection.endpoints());
        errdefer self.endpoint_resolver.deinit();
        self.looper = looper;
        looper.start() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.LooperFailure,
        };
    }

    fn releaseConnection(self: *ConnectionDaemon) void {
        const connection = self.connection orelse return;
        // Join the looper before freeing Connection, and retain the looper
        // object until Connection has released the sessions borrowing it.
        self.looper.stop() catch |err| {
            log.writef(.debug, "Unable to stop connection looper: {s}", .{@errorName(err)});
        };
        connection.destroy();
        self.destroyTunnel();
        self.looper.deinit();
        self.daemon.allocator.destroy(self.looper);
        self.endpoint_resolver.deinit();
        self.connection = null;
    }

    // Runs as one actor operation; shutdown quiesces protocol activity
    // while the looper remains free to process the detach commands.
    fn stopConnection(
        self: *ConnectionDaemon,
        timeout_ms: u32,
        reason: Connection.ShutdownReason,
    ) !void {
        _ = try self.callOnLooper(.{ .shutdown = reason });
        try self.detachLooperSides();
        _ = try self.callOnLooper(.{ .stop = timeout_ms });
    }

    fn detachLooperSides(self: *ConnectionDaemon) Looper.DetachError!void {
        if (self.looper.isTunAttached()) try self.looper.detach(.tun);
        if (self.looper.isLinkAttached()) try self.looper.detach(.link);
    }

    fn destroyTunnel(self: *ConnectionDaemon) void {
        if (self.tunnel) |*tunnel| tunnel.deinit();
        self.tunnel = null;
    }

    fn startConnection(self: *ConnectionDaemon) void {
        self.internalEvaluateConnection(true);
    }

    fn doEvaluateConnection(self: *ConnectionDaemon) void {
        self.internalEvaluateConnection(false);
    }

    fn internalEvaluateConnection(self: *ConnectionDaemon, force: bool) void {
        if (self.daemon.state != .started) {
            log.write(.info, "Ignore evaluation, daemon not started");
            return;
        }
        if (self.connection == null) return;
        if (self.is_evaluating_connection) {
            log.write(.debug, "Ignore evaluation, another one pending");
            return;
        }

        self.is_evaluating_connection = true;
        defer self.is_evaluating_connection = false;

        if (!force and !self.monitor.isReachable()) {
            log.write(.info, "Ignore evaluation, wait for reachable network");
            _ = self.gate.setEnabled(true);
            return;
        }

        log.write(.info, "Pause connection gate during reconnection");
        _ = self.gate.setEnabled(false);

        log.write(.notice, "Start connection");
        const endpoint = self.setupLink() catch |err| {
            log.writef(.err, "Unable to set up link: {s}", .{@errorName(err)});
            _ = self.daemon.handleStartError(error.UnableToStart);
            self.scheduleResumeGate();
            return;
        };
        // EndpointResolver owns this endpoint; perform() keeps the borrow
        // valid until Connection has consumed it on the looper.
        const link: net.LinkDescriptor = .{
            .endpoint = endpoint,
            .looper = self.looper,
        };
        // Performs connection.start() on the looper thread. Remember to
        // detach the link on failure.
        self.trackConnectionStatus(.connecting);
        const did_start = self.callOnLooper(.{ .start = link }) catch |err| {
            log.writef(.err, "Unable to start connection: {s}", .{@errorName(err)});
            _ = self.daemon.handleStartError(switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.DNSResolutionFailure => error.DNSResolutionFailure,
                error.Timeout => error.Timeout,
                else => error.UnableToStart,
            });
            self.trackConnectionStatus(.disconnected);
            self.detachLooperSides() catch {};
            self.scheduleResumeGate();
            return;
        };
        if (!did_start) {
            log.write(.err, "Connection could not start");
            self.trackConnectionStatus(.disconnected);
            self.detachLooperSides() catch {};
            self.scheduleResumeGate();
            return;
        }
        // Connection attempted on the looper in background.
    }

    fn setupLink(self: *ConnectionDaemon) !api.ExtendedEndpoint {
        log.write(.notice, "Create new link");
        log.write(.notice, "Cycle to next endpoint");
        // FIXME: ###, Pick endpoint, resolve DNS, and connect link atomically in SocketFactory
        const reachability = self.factory.currentReachability();
        const endpoint = try self.endpoint_resolver.next(
            &self.resolver,
            reachability,
            self.daemon.options.connection_options.dns_timeout,
        );
        log.writef(.notice, "Connect to {s}", .{endpoint});
        const descriptor = try self.factory.create(
            self.daemon.allocator,
            endpoint,
            reachability,
            self.daemon.options.connection_options.link_activity_timeout,
        );
        // The looper takes ownership only after a successful attach.
        errdefer descriptor.io.cleanup();
        log.write(.notice, "Link is active");
        log.writef(.info, "Link type is {s}", .{
            endpoint.proto.socket_type.raw(),
        });
        log.write(.info, "Attach LINK");
        try self.looper.attach(.{
            .pair = .{
                .link = descriptor,
            },
            .on_read = .{
                .context = self,
                .callback = onLinkRead,
            },
            .on_failure = .{
                .context = self,
                .callback = onLinkFailure,
            },
        });
        return endpoint;
    }

    fn scheduleResumeGate(self: *ConnectionDaemon) void {
        if (self.daemon.state != .started) {
            log.write(.info, "Ignore resume connection gate, daemon not started");
            return;
        }
        const delay_ms = self.daemon.options.reconnection_delay_ms;
        log.writef(.info, "Resume connection gate in {} milliseconds", .{delay_ms});

        // Contextually cancels the previous attempt
        self.resume_gate_timer.scheduleReplacing(delay_ms, onResumeGate, self) catch |err| {
            log.writef(.err, "Unable to schedule resume connection gate, enqueue resume: {s}", .{@errorName(err)});
            // Finish the current evaluation and drain queued connection events
            // before the gate can start another attempt.
            self.actor.schedule(.resumeGate) catch |schedule_err| {
                log.writef(.fault, "Unable to enqueue resume connection gate: {s}", .{@errorName(schedule_err)});
                self.daemon.requestCancellation(null, true);
            };
        };
    }

    fn doResumeGate(self: *ConnectionDaemon) void {
        if (self.daemon.state != .started) {
            log.write(.info, "Ignore resume connection gate, daemon not started");
            return;
        }
        log.write(.info, "Resume connection gate now");
        _ = self.gate.setEnabled(true);
    }

    // The ready event gates the signals from:
    //
    // - gate.updateStatus()
    // - gate.updateReachability()
    fn onNetworkReady(ctx: ?*anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        log.write(.notice, "Network is ready, start connection");
        self.actor.perform(void, .evaluateConnection) catch |err| {
            log.writef(.err, "Unable to evaluate connection: {s}", .{@errorName(err)});
        };
    }

    fn isReachable(ctx: ?*const anyopaque) bool {
        const self: *const ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        return self.monitor.isReachable();
    }

    // Updates the gate on the actor so that a ready transition and the
    // resulting connection start are serialized with the corresponding
    // network-change event.
    fn handleReachabilitySignal(self: *ConnectionDaemon, reachability: io.ReachabilityInfo) void {
        _ = self.gate.updateReachability(reachability.reachable);
        self.handleReachability(reachability);
    }

    // Forwards the event to the underlying connection
    fn handleReachability(self: *ConnectionDaemon, reachability: io.ReachabilityInfo) void {
        if (self.daemon.state != .started) return;
        if (self.connection == null) return;
        _ = self.callOnLooper(.{ .reachability = reachability }) catch return;
    }

    // Forwards the event to the underlying connection
    fn handleBetterPath(self: *ConnectionDaemon) void {
        if (self.daemon.state != .started) return;
        if (self.connection == null) return;
        _ = self.callOnLooper(.better_path) catch return;
    }

    fn handleConnectionEstablished(
        self: *ConnectionDaemon,
        success: net.Connection.Events.Success,
    ) !void {
        if (self.daemon.state != .started) return;
        if (self.daemon.snapshot_publisher.environment.connection_status != .connecting) return;
        if (self.connection == null) return;

        self.tunnel = self.daemon.controller.setTunnelSettings(success.info) catch |err| {
            log.writef(.fault, "Unable to establish tunnel settings: {s}", .{@errorName(err)});
            return error.TunNotAvailable;
        };
        const active_tunnel = if (self.tunnel) |*value| value else {
            log.write(.fault, "Unable to get tun device");
            return error.TunNotAvailable;
        };
        const fd = active_tunnel.muxDescriptor() orelse {
            log.write(.fault, "Unable to get mux descriptor");
            return error.MuxFailure;
        };
        const descriptor = Looper.Descriptor{
            .fd = fd,
            .io = active_tunnel.nativeIO(),
        };

        log.write(.info, "Attach TUN");
        self.looper.attach(.{
            .pair = .{
                .tun = descriptor,
            },
            .on_read = .{
                .context = self,
                .callback = onTunnelRead,
            },
            .on_failure = .{
                .context = self,
                .callback = onTunnelFailure,
            },
        }) catch return error.TunNotAvailable;

        self.trackConnectionStatus(.connected);
    }

    fn handleConnectionFailed(
        self: *ConnectionDaemon,
        failure: net.Connection.Events.Failure,
    ) void {
        if (self.daemon.state != .started) return;
        if (self.connection == null) return;
        // Failure callbacks leave the session owned by Connection. Finalize
        // it on the looper before the gate can start another attempt.
        self.stopConnection(0, .{ .failure = failure.disposition }) catch |err| {
            log.writef(.err, "Unable to stop failed connection: {s}", .{@errorName(err)});
            return;
        };
        self.clearConnectionTunnel();
        self.daemon.handleLastError(failure.code);
        switch (failure.disposition) {
            .reconnect => self.trackConnectionStatus(.disconnected),
            .cancel => self.cancelConnection(failure.code),
        }
    }

    fn handleConnectionStopped(self: *ConnectionDaemon) void {
        if (self.daemon.state != .started) return;
        if (self.daemon.snapshot_publisher.environment.connection_status == .disconnected) return;
        self.clearConnectionTunnel();
        self.trackConnectionStatus(.disconnected);
    }

    fn trackConnectionStatus(self: *ConnectionDaemon, status: api.ConnectionStatus) void {
        self.daemon.snapshot_publisher.setConnectionStatus(status);
        switch (status) {
            .connected => {
                self.daemon.emitRemove(.last_error_code);
                self.daemon.snapshot_publisher.setLastError(null);
                self.daemon.controller.setReasserting(false);
            },
            .connecting => {
                self.daemon.emitRemove(.last_error_code);
                self.daemon.snapshot_publisher.setLastError(null);
                self.daemon.controller.setReasserting(true);
            },
            .disconnecting => {},
            .disconnected => {
                self.daemon.resetDataCount();
                self.daemon.controller.setReasserting(false);
                self.scheduleResumeGate();
            },
        }
        self.daemon.emitStatus(status);
        self.daemon.snapshot_publisher.publishCurrentSnapshot(true);
        _ = self.gate.updateStatus(status);
    }

    fn cancelConnection(self: *ConnectionDaemon, code: ?api.PartoutErrorCode) void {
        self.daemon.enterFailedState();
        self.daemon.controller.setReasserting(false);
        if (!self.daemon.options.cancels_unrecoverable and
            self.daemon.snapshot_publisher.environment.connection_status != .disconnected)
        {
            self.trackConnectionStatus(.disconnected);
        }
        self.daemon.requestCancellation(code, false);
    }

    fn handleLooperTermination(
        self: *ConnectionDaemon,
        failure: ?Looper.Failure,
    ) void {
        if (self.daemon.state != .started) return;

        log.write(.fault, "ConnectionDaemon-owned looper terminated");

        if (partoutCodeForLooperFailure(failure)) |code| {
            self.daemon.handleLastError(code);
        }

        // onLooperTerminate() already finalized Connection on its looper.
        // No further Connection operations can be dispatched to that queue.
        self.resume_gate_timer.cancel();
        self.actor.schedule(.recoverConnection) catch |err| {
            log.writef(.fault, "Unable to schedule connection recovery: {s}", .{@errorName(err)});
            self.daemon.controller.setReasserting(false);
            self.daemon.requestCancellation(partoutCodeForLooperFailure(failure), true);
        };
    }

    fn recoverConnection(self: *ConnectionDaemon) void {
        if (self.daemon.state != .started) return;

        log.write(.notice, "Replace connection after terminal looper");
        _ = self.gate.setEnabled(false);
        self.releaseConnection();
        // Reset both the published status and gate before replacing the
        // connection. Recovery starts immediately; only a failed attempt needs
        // the delayed retry normally scheduled by the disconnected status.
        self.daemon.controller.clearTunnelSettings(false);
        self.trackConnectionStatus(.disconnected);
        self.resume_gate_timer.cancel();
        if (self.daemon.state != .started) return;
        self.createConnection() catch |err| {
            log.writef(.fault, "Unable to replace connection: {s}", .{@errorName(err)});
            const code = self.daemon.handleStartError(err);
            self.daemon.requestCancellation(code, true);
            return;
        };

        if (self.daemon.state == .started) {
            self.startConnection();
        }
    }

    fn clearConnectionTunnel(self: *ConnectionDaemon) void {
        if (self.connection != null) {
            self.detachLooperSides() catch {};
            self.destroyTunnel();
        }
        self.daemon.controller.clearTunnelSettings(false);
    }

    fn pause(self: *ConnectionDaemon) void {
        self.resume_gate_timer.cancel();
        _ = self.gate.setEnabled(false);
    }

    //#endregion

    //#region Looper thread - I/O and termination callbacks

    // The looper invokes these callbacks against the current Connection. They may
    // run protocol work directly, but must never wait for the actor. Termination
    // finalizes protocol state here, then enqueues actor-owned recovery.

    fn onLinkRead(ctx: ?*anyopaque, packets: Looper.Packets) !Looper.ReadAction {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onLinkRead but no connection");
        return conn.submitPackets(.link, packets);
    }

    fn onLinkFailure(ctx: ?*anyopaque, failure: Looper.Failure) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onLinkFailure but no connection");
        conn.looperFailed(.link, failure);
    }

    fn onTunnelRead(ctx: ?*anyopaque, packets: Looper.Packets) !Looper.ReadAction {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onTunnelRead but no connection");
        return conn.submitPackets(.tun, packets);
    }

    fn onTunnelFailure(ctx: ?*anyopaque, failure: Looper.Failure) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onTunnelFailure but no connection");
        conn.looperFailed(.tun, failure);
    }

    fn onLooperTerminate(ctx: ?*anyopaque, failure: ?Looper.Failure) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        self.connection.?.looperTerminated(failure);
        self.actor.schedule(.{ .onLooperTerminated = failure }) catch |err| {
            log.writef(.debug, "Ignore terminal looper after actor shutdown: {s}", .{@errorName(err)});
        };
    }

    //#endregion

    //#region Actor interface

    // Mailbox messages enter through perform on the actor. actorDidFinish also
    // runs on that thread and completes serialized shutdown before it exits.

    const Actor = core.actor.ActorWithFinish(
        ConnectionDaemon,
        Message,
        Error,
        perform,
        actorDidFinish,
    );

    const Message = union(enum) {
        start,
        hold,
        stop,
        evaluateConnection,
        resumeGate,
        onReachability: io.ReachabilityInfo,
        onBetterPath,
        onConnectionEstablished: net.Connection.Events.Success,
        onConnectionFailed: net.Connection.Events.Failure,
        onConnectionStopped,
        onConnectionSetEnvironmentValue: struct {
            key: []const u8,
            value: ?[]const u8,
        },
        onConnectionDataCount: api.DataCount,
        onLooperTerminated: ?Looper.Failure,
        recoverConnection,
    };

    fn perform(self: *ConnectionDaemon, comptime Result: type, message: Message) Error!Result {
        switch (message) {
            .start => try self.doStart(),
            .hold => self.doHold(),
            .stop => self.doStop(.clear_environment),
            .evaluateConnection => self.doEvaluateConnection(),
            .resumeGate => self.doResumeGate(),
            .onReachability => |reachability| self.handleReachabilitySignal(reachability),
            .onBetterPath => self.handleBetterPath(),
            .onConnectionEstablished => |arg| {
                var success = arg;
                defer success.remote_endpoint.deinit(self.daemon.allocator);
                defer success.info.deinit(self.daemon.allocator);
                self.handleConnectionEstablished(success) catch |err| {
                    log.writef(.fault, "Unable to establish connection: {s}", .{@errorName(err)});
                    self.handleConnectionFailed(.{
                        .code = .tunNotAvailable,
                        .disposition = .reconnect,
                    });
                };
            },
            .onConnectionFailed => |arg| self.handleConnectionFailed(arg),
            .onConnectionStopped => self.handleConnectionStopped(),
            .onConnectionSetEnvironmentValue => |update| {
                defer self.daemon.allocator.free(update.key);
                defer if (update.value) |bytes| self.daemon.allocator.free(bytes);
                // Finalization can queue a clear while the actor is stopping.
                // Deliver it, but do not restore stale values after shutdown.
                if (self.daemon.state == .started or update.value == null) {
                    self.daemon.controller.setEnvironmentValue(update.key, update.value);
                }
            },
            .onConnectionDataCount => |count| self.daemon.handleDataCount(count),
            .onLooperTerminated => |failure| self.handleLooperTermination(failure),
            .recoverConnection => self.recoverConnection(),
        }
    }

    fn actorDidFinish(self: *ConnectionDaemon) void {
        if (self.is_deinitializing) return;

        log.write(.fault, "ConnectionDaemon actor terminated");

        // The callback still runs on the actor thread, so it can complete the
        // normal serialized stop before the worker exits. The host cancellation
        // then owns final ConnectionDaemon/Looper deinitialization.
        self.doStop(.preserve_environment);
        self.daemon.controller.setReasserting(false);
        self.daemon.requestCancellation(null, true);
    }

    //#endregion

    //#region Looper interface

    // The actor submits a stack-backed request through callOnLooper and waits for
    // completion. CallOnLooper.run executes on the looper; connection callbacks
    // only enqueue actor messages, allowing the actor to wait without a cycle.

    const CallOnLooper = struct {
        connection: Connection,
        events: Connection.Events,
        operation: union(enum) {
            start: net.LinkDescriptor,
            shutdown: Connection.ShutdownReason,
            stop: u32,
            reachability: io.ReachabilityInfo,
            better_path,
        },

        fn run(ctx: ?*anyopaque) !bool {
            const request: *const CallOnLooper = @ptrCast(@alignCast(ctx.?));
            switch (request.operation) {
                .start => |link| return request.connection.startV2(link),
                .shutdown => |reason| request.connection.shutdown(reason),
                .stop => |timeout| request.connection.stop(timeout, request.events),
                .reachability => |info| request.connection.networkChange(info, request.events),
                .better_path => request.connection.betterPath(request.events),
            }
            return true;
        }
    };

    // Only the actor waits. Connection callbacks enqueue actor messages.
    fn callOnLooper(
        self: *ConnectionDaemon,
        operation: @FieldType(CallOnLooper, "operation"),
    ) !bool {
        var request = CallOnLooper{
            .connection = self.connection.?,
            .events = self.events(),
            .operation = operation,
        };
        return self.looper.perform(bool, &request, CallOnLooper.run);
    }

    //#endregion
};

// MARK: - Error mapping

fn partoutCodeForDaemonStartError(err: StartError) api.PartoutErrorCode {
    return switch (err) {
        error.UnsupportedCryptoBackend,
        => .crypto,
        error.InvalidJson,
        error.InvalidModel,
        error.InvalidProfile,
        error.UnsupportedModel,
        => .decoding,
        error.DNSResolutionFailure,
        => .dnsFailure,
        error.Timeout,
        => .timeout,
        error.IncompleteModule => .incompleteModule,
        error.MissingConnectionImplementation => .requiredImplementation,
        error.OutOfMemory => .outOfMemory,
        error.SocketConfiguration => .socketConfiguration,
        error.TunNotAvailable => .tunNotAvailable,
        error.AlreadyStarted,
        error.Closed,
        error.IdGeneration,
        error.LooperFailure,
        error.UnableToStart,
        => .unhandled,
    };
}

fn partoutCodeForLooperFailure(opt_failure: ?Looper.Failure) ?api.PartoutErrorCode {
    const failure = opt_failure orelse return null;
    return switch (failure) {
        .wait, .system, .io => .ioFailure,
        .user => .unhandled,
    };
}

pub const testing = struct {
    pub const codeForDaemonStartError = partoutCodeForDaemonStartError;
    pub const codeForLooperFailure = partoutCodeForLooperFailure;
};
