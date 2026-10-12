// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Daemon owns the shared profile, lifecycle state, controller, and reporting.
//! Its private SettingsDaemon and ConnectionDaemon implementations borrow it
//! and supply the behavior for each profile type.
//!
//! SettingsDaemon is synchronous; callers serialize its controls. ConnectionDaemon
//! owns an actor that serializes connection work and updates to shared state.
//! Connection callbacks enqueue actor messages from runtime and worker threads.
//! Ordinary reconnects retain Connection; terminal looper failure ends the event loop.
//! Stop before destroy; monitors must cease callbacks after setEventHandler(null).

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const conn_mod = @import("connection.zig");
const daemon_mod = @import("daemon.zig");
const helpers = @import("daemon_helpers.zig");
const io = @import("io.zig");
const looper_mod = @import("looper_v2.zig");
const sandbox = @import("sandbox.zig");

const api = core.api;
const io_c = io.io_c;
const log = core.logging;
const Connection = conn_mod.Connection;
const ConnectionGate = helpers.ConnectionGate;
const ConnectionRegistry = conn_mod.ConnectionRegistry;
const EndpointResolver = net.EndpointResolver;
const Looper = looper_mod.Looper;
const RemoteDescriptor = conn_mod.RemoteDescriptor;
const SnapshotPublisher = helpers.SnapshotPublisher;
const activeConnectionModule = conn_mod.activeConnectionModule;

pub const Error = daemon_mod.Error;

const StartError = Error || conn_mod.StartError ||
    sandbox.TunnelController.Error;

// Both implementations expose the same host-facing contract.
pub const EventKey = daemon_mod.EventKey;
pub const Events = daemon_mod.Events;
pub const Context = daemon_mod.Context;

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
        log.write(.notice, "Using daemon v2");
        var profile = try original_profile.clone(allocator);
        errdefer profile.deinit(allocator);
        log.write(.notice, "Decoded profile:");
        log.writeProfile(.notice, &profile);

        const self = try allocator.create(Daemon);
        errdefer allocator.destroy(self);
        const snapshot_publisher = SnapshotPublisher.init(
            allocator,
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
        self.snapshot_publisher.deinit();
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
        self.handleLastError(.{ .code = code });
        self.controller.setReasserting(false);
        return code;
    }

    fn handleLastError(self: *Daemon, err_pair: api.PartoutErrorPair) void {
        self.resetDataCount();
        self.snapshot_publisher.setLastError(err_pair);
        self.snapshot_publisher.publishCurrentSnapshot(true);
        if (self.options.events) |e| e.last_error(e.ctx, err_pair);
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

    fn requestCancellation(self: *Daemon, err_pair: ?api.PartoutErrorPair, force: bool) void {
        self.enterFailedState();
        if (self.cancellation_requested) return;
        if (!force and !self.options.cancels_unrecoverable) return;
        self.cancellation_requested = true;
        self.controller.cancelTunnelConnection(err_pair);
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
            daemon.requestCancellation(.{ .code = code }, false);
            return;
        };
        if (maybe_info) |*info| {
            defer info.deinit(daemon.allocator);
            const tun = daemon.controller.setTunnelSettings(info.*) catch |err| {
                log.writef(.fault, "Unable to set settings-only tunnel: {s}", .{@errorName(err)});
                const code = daemon.handleStartError(err);
                daemon.requestCancellation(.{ .code = code }, false);
                return;
            };
            tun.destroy();
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

    // Event loop
    mux: io_c.pp_mux,
    actor: std.Thread,
    actor_id: ?std.Thread.Id,
    looper: *Looper,
    jobs: core.Fifo(Job),
    jobs_mutex: core.Mutex,
    jobs_condition: core.concurrency.Condition = .{},
    is_running: bool,

    // Internal state
    connection: ?Connection,
    rebind_pending: std.atomic.Value(bool),
    // Valid while connection is non-null; only this class accesses them.
    endpoint_resolver: ?EndpointResolver,
    gate: ConnectionGate,
    resume_gate_timer: Looper.Timer,
    is_evaluating_connection: bool,

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
        const mux = io_c.pp_mux_create(2) orelse return error.LooperFailure;
        errdefer io_c.pp_mux_free(mux);
        const looper = Looper.create(allocator, .{
            .mux = mux,
            // FIXME: ###, Delete after v2
            .on_finish = .{
                .callback = struct {
                    fn call(_: ?*anyopaque, _: ?Looper.Failure) void {
                        unreachable;
                    }
                }.call,
                .context = self,
            },
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.MuxFailure => error.LooperFailure,
        };
        errdefer looper.destroy();
        self.* = .{
            .daemon = daemon,
            .mux = mux,
            .actor = undefined,
            .actor_id = null,
            .looper = looper,
            .jobs = .{},
            .jobs_mutex = .{},
            .jobs_condition = .{},
            .is_running = true,
            .module = module,
            .registry = objects.registry,
            .resolver = objects.resolver,
            .factory = objects.factory,
            .monitor = objects.monitor,
            .connection = null,
            .rebind_pending = .init(false),
            .endpoint_resolver = null,
            .gate = ConnectionGate.init(null),
            .resume_gate_timer = .{},
            .is_evaluating_connection = false,
        };
        errdefer self.jobs_mutex.deinit();
        errdefer self.jobs_condition.deinit();
        errdefer self.gate.deinit();
        self.actor = std.Thread.spawn(.{}, run, .{self}) catch return error.OutOfMemory;
        return self;
    }

    fn destroy(self: *ConnectionDaemon) void {
        // Signal thread stop and wait for it to finish.
        self.shutdown();
        self.actor.join();
        if (self.connection != null)
            @panic("ConnectionDaemon.destroy() cannot release live connection resources");
        self.looper.destroy();

        // Daemon checked the shared lifecycle precondition. Drain callbacks
        // before releasing this implementation and its borrowed Daemon.

        self.monitor.setEventHandler(null);
        self.monitor.stopObserving();
        self.gate.stopObserving();
        self.gate.deinit();
        self.jobs_mutex.deinit();
        self.jobs_condition.deinit();
        io_c.pp_mux_free(self.mux);
        self.daemon.allocator.destroy(self);

        log.write(.debug, "Deinit daemon");
    }

    fn start(self: *ConnectionDaemon) Error!void {
        return self.perform(void, .start);
    }

    fn hold(self: *ConnectionDaemon) void {
        self.perform(void, .hold) catch return;
    }

    fn stop(self: *ConnectionDaemon) void {
        self.perform(void, .stop) catch return;
    }

    //#endregion

    //#region Any thread - asynchronous events

    // Network and protocol producers may hold locks needed by actor work. These
    // callbacks enqueue messages without waiting or changing lifecycle state; borrowed
    // establishment data is cloned. Protocol events may arrive on actor or I/O workers.

    // This is where connection events are rerouted through the actor
    fn events(self: *ConnectionDaemon) Connection.Events {
        return .{
            .ctx = self,
            .established = onConnectionEstablished,
            .needs_rebind = onConnectionNeedsRebind,
            .failed = onConnectionFailed,
            .stopped = onConnectionStopped,
            .set_env = onConnectionSetEnvironmentValue,
            .data_count = onConnectionDataCount,
            // FIXME: ###, Deprecated callbacks must never be emitted by a v2 connection.
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
        var info = success.info.clone(self.daemon.allocator) catch {
            onConnectionFailed(ctx, .{ .err_pair = .{ .code = .outOfMemory }, .disposition = .reconnect });
            return;
        };
        self.schedule(.{ .onConnectionEstablished = .{
            .remote_endpoint = success.remote_endpoint,
            .info = info,
        } }) catch |err| {
            info.deinit(self.daemon.allocator);
            log.writef(.fault, "Unable to enqueue established connection: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionNeedsRebind(ctx: *anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        if (self.rebind_pending.swap(true, .acq_rel)) return;
        self.schedule(.onConnectionNeedsRebind) catch |err| {
            self.rebind_pending.store(false, .release);
            log.writef(.err, "Unable to enqueue connection refresh: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionFailed(ctx: *anyopaque, failure: Connection.Events.Failure) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        self.schedule(.{ .onConnectionFailed = failure }) catch |err| {
            log.writef(.err, "Unable to enqueue connection failure: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionStopped(ctx: *anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx));
        self.schedule(.onConnectionStopped) catch |err| {
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
        self.schedule(.{ .onConnectionSetEnvironmentValue = .{
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
        self.schedule(.{ .onConnectionDataCount = data_count }) catch |err| {
            log.writef(.err, "Unable to report connection data count: {s}", .{@errorName(err)});
        };
    }

    fn legacyStatus(_: *anyopaque, _: api.ConnectionStatus) void {
        @panic("Unimplemented");
    }

    fn legacyLastError(_: *anyopaque, _: api.PartoutErrorPair) void {
        @panic("Unimplemented");
    }

    fn legacyCancel(_: *anyopaque, _: ?api.PartoutErrorPair) void {
        @panic("Unimplemented");
    }

    // Network callbacks may originate while the platform owns a lock that is
    // also needed by tunnel-controller callbacks. Never wait for the actor
    // here: starting a connection can synchronously report a snapshot back to
    // the platform and would otherwise deadlock with that lock held.
    fn onReachability(ctx: ?*anyopaque, reachability: io.ReachabilityInfo) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        self.schedule(.{ .onReachability = reachability }) catch |err| {
            log.writef(.err, "Unable to enqueue reachability: {s}", .{@errorName(err)});
        };
    }

    // Like reachability, better-path notifications come from platform code
    // whose locks must be released before calling back into the controller.
    fn onBetterPath(ctx: ?*anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        self.schedule(.onBetterPath) catch |err| {
            log.writef(.err, "Unable to enqueue better path: {s}", .{@errorName(err)});
        };
    }

    //#endregion

    //#region Actor thread - delayed gate resumption

    // Looper timers run inside loopOnce(). Defer gate changes until it returns,
    // because a ready transition may start a connection and attach I/O.

    // This is scheduled with a delay
    fn onResumeGate(ctx: ?*anyopaque) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        self.schedule(.resumeGate) catch |err| {
            log.writef(.err, "Unable to resume connection gate: {s}", .{@errorName(err)});
            self.daemon.requestCancellation(null, true);
        };
    }

    //#endregion

    //#region Actor thread - connection lifecycle and state

    // The actor serializes these methods and their updates to the shared Daemon.
    // Gate callbacks and protocol controls run inline on the same actor thread.

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
        self.looper.cancelTimer(&self.resume_gate_timer);

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
    // complete state before starting any looper callbacks.
    fn createConnection(self: *ConnectionDaemon) Error!void {
        std.debug.assert(self.connection == null);
        const connection = try self.registry.createConnection(self.daemon.allocator, self.module, .{
            .profile = &self.daemon.profile,
            .options = self.daemon.options.connection_options,
            .cache_dir = self.daemon.options.cache_dir,
            .events = self.events(),
            .writer = net.ConnectionWriter.init(self.looper, &writer_vtable),
            // FIXME: ###, Delete all these from Sandbox
            .controller = self.daemon.controller,
            .resolver = self.resolver,
            .factory = self.factory,
            .looper = undefined,
        });
        errdefer connection.destroy();
        self.connection = connection;
        errdefer self.connection = null;
        self.endpoint_resolver = if (connection.endpoints()) |endpoints| EndpointResolver.init(self.daemon.allocator, endpoints) else null;
        errdefer if (self.endpoint_resolver) |*resolver| resolver.deinit();
    }

    fn releaseConnection(self: *ConnectionDaemon) void {
        const connection = self.connection orelse @panic("releaseConnection but no connection");
        connection.destroy();
        if (self.endpoint_resolver) |*resolver| resolver.deinit();
        self.endpoint_resolver = null;
        self.connection = null;
    }

    // Runs as one actor operation; shutdown quiesces protocol activity before
    // detaching I/O and releasing protocol state.
    fn stopConnection(
        self: *ConnectionDaemon,
        timeout_ms: u32,
        reason: Connection.ShutdownReason,
    ) !void {
        const connection = self.connection orelse @panic("stopConnection but no connection");
        connection.shutdown(reason);
        try self.detachLooperSides();
        connection.stop(timeout_ms, self.events());
    }

    fn detachLooperSides(self: *ConnectionDaemon) Looper.DetachError!void {
        if (self.looper.isTunAttached()) try self.looper.detach(.tun);
        if (self.looper.isLinkAttached()) try self.looper.detach(.link);
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
        const connection = self.connection orelse @panic("internalEvaluateConnection but no connection");
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
        const remote = self.setupLink() catch |err| {
            log.writef(.err, "Unable to set up link: {s}", .{@errorName(err)});
            _ = self.daemon.handleStartError(error.UnableToStart);
            self.scheduleResumeGate();
            return;
        };
        // Start on the actor, detaching any looper-owned link on failure.
        self.trackConnectionStatus(.connecting);
        // Entering startV2 transfers a connection-owned link, even on failure.
        const result = connection.startV2(remote) catch |err| {
            log.writef(.err, "Unable to start connection: {s}", .{@errorName(err)});
            _ = self.daemon.handleStartError(switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.DNSResolutionFailure => error.DNSResolutionFailure,
                error.Timeout => error.Timeout,
                else => error.UnableToStart,
            });
            self.trackConnectionStatus(.disconnected);
            self.stopConnection(0, .{ .failure = .reconnect }) catch {};
            self.scheduleResumeGate();
            return;
        };
        switch (result) {
            .started => {}, // Asynchronous establishment continues through events.
            .established => |success| {
                var owned = success;
                defer owned.info.deinit(self.daemon.allocator);
                // Complete startup before yielding to queued reachability events.
                self.handleConnectionEstablished(success) catch |err| {
                    log.writef(.fault, "Unable to establish connection: {s}", .{@errorName(err)});
                    self.handleConnectionFailed(.{
                        .err_pair = .{ .code = partoutCodeForDaemonStartError(err) },
                        .disposition = .reconnect,
                    });
                };
            },
            .failed => {
                log.write(.err, "Connection could not start");
                self.trackConnectionStatus(.disconnected);
                self.stopConnection(0, .{ .failure = .reconnect }) catch {};
                self.scheduleResumeGate();
            },
        }
    }

    fn setupLink(self: *ConnectionDaemon) !RemoteDescriptor {
        const connection = self.connection orelse @panic("setupLink but no connection");
        const conn_options = self.daemon.options.connection_options;
        var remote = RemoteDescriptor{};
        if (connection.daemon_io == .none) return remote;
        log.write(.notice, "Create new link");
        const reachability = self.factory.currentReachability();
        var endpoint: ?api.ExtendedEndpoint = null;
        if (self.endpoint_resolver) |*resolver| {
            log.write(.notice, "Cycle to next endpoint");
            // FIXME: ###, Pick endpoint, resolve DNS, and connect atomically in SocketFactory.
            endpoint = try resolver.next(
                &self.resolver,
                reachability,
                conn_options.dns_timeout,
            );
            log.writef(.notice, "Connect to {s}", .{endpoint.?});
        }
        remote.endpoint = if (endpoint) |resolved| try net.SocketEndpoint.init(resolved) else null;
        const unconnected = if (remote.endpoint) |resolved|
            resolved.plainSocketType() == .udp and !conn_options.connect_udp
        else
            true;
        var descriptor = try self.factory.create(
            self.daemon.allocator,
            if (unconnected) null else endpoint,
            connection.local_port,
            reachability,
            conn_options.link_activity_timeout,
        );
        // Ownership transfers to the looper on attach, or to the connection on start.
        errdefer descriptor.cleanup();
        if (unconnected) remote.local_port = (try descriptor.localAddress()).port;
        // Passive protocols retain their bind across host socket replacement.
        if (self.endpoint_resolver == null) self.connection.?.local_port = remote.local_port;
        log.write(.notice, "Link is active");
        log.writef(.info, "Link type is {s}", .{
            if (remote.endpoint) |value| value.type.raw() else api.IPSocketType.udp.raw(),
        });
        if (connection.daemon_io == .looper) {
            log.write(.info, "Attach LINK");
            try self.looper.attach(.{
                .pair = .{ .link = descriptor },
                .on_read = .{ .context = self, .callback = onLinkRead },
                .on_failure = .{ .context = self, .callback = onLinkFailure },
            });
        }
        remote.link = descriptor;
        return remote;
    }

    fn scheduleResumeGate(self: *ConnectionDaemon) void {
        if (self.daemon.state != .started) {
            log.write(.info, "Ignore resume connection gate, daemon not started");
            return;
        }
        const delay_ms = self.daemon.options.reconnection_delay_ms;
        log.writef(.info, "Resume connection gate in {} milliseconds", .{delay_ms});

        // Contextually cancels the previous attempt
        self.looper.scheduleTimer(&self.resume_gate_timer, delay_ms, .{
            .context = self,
            .callback = onResumeGate,
        }) catch |err| {
            log.writef(.err, "Unable to schedule resume connection gate, defer resume: {s}", .{@errorName(err)});
            // Finish the current evaluation and drain queued connection events
            // before the gate can start another attempt.
            self.looper.cancelTimer(&self.resume_gate_timer);
            self.schedule(.resumeGate) catch |schedule_err| {
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
        self.doEvaluateConnection();
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
        const connection = self.connection orelse @panic("handleReachability but no connection");
        connection.networkChange(reachability, self.events());
    }

    // Forwards the event to the underlying connection
    fn handleBetterPath(self: *ConnectionDaemon) void {
        if (self.daemon.state != .started) return;
        const connection = self.connection orelse @panic("handleBetterPath but no connection");
        connection.betterPath(self.events());
    }

    fn handleConnectionEstablished(
        self: *ConnectionDaemon,
        success: net.Connection.Events.Success,
    ) StartError!void {
        if (self.daemon.state != .started) return;
        if (self.daemon.snapshot_publisher.environment.connection_status != .connecting) return;
        const connection = self.connection orelse @panic("handleConnectionEstablished but no connection");

        const tunnel = self.daemon.controller.setTunnelSettings(success.info) catch |err| {
            log.writef(.fault, "Unable to establish tunnel settings: {s}", .{@errorName(err)});
            return error.TunNotAvailable;
        };
        // Retain ownership until descriptor preparation and handoff succeed.
        errdefer tunnel.destroy();
        const descriptor = tunnel.tunDescriptor() catch return error.TunNotAvailable;
        if (connection.daemon_io != .looper) {
            try connection.commit(descriptor);
            self.trackConnectionStatus(.connected);
            return;
        }

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
        // Failure callbacks leave the session owned by Connection. Finalize
        // it before the gate can start another attempt.
        self.stopConnection(0, .{ .failure = failure.disposition }) catch |err| {
            log.writef(.err, "Unable to stop failed connection: {s}", .{@errorName(err)});
            return;
        };
        self.clearConnectionTunnel();
        self.daemon.handleLastError(failure.err_pair);
        switch (failure.disposition) {
            .reconnect => self.trackConnectionStatus(.disconnected),
            .cancel => self.cancelConnection(failure.err_pair),
        }
    }

    fn handleConnectionNeedsRebind(self: *ConnectionDaemon) !void {
        defer self.rebind_pending.store(false, .release);
        if (self.daemon.state != .started) return;
        const connection = self.connection orelse @panic("handleConnectionNeedsRebind but no connection");
        // Go may have established while its success event is still queued on
        // this actor. Refresh must also finish in that connecting interval.
        switch (self.daemon.snapshot_publisher.environment.connection_status) {
            .connecting, .connected => {},
            else => return,
        }
        log.write(.info, "Refresh LINK, retaining TUN and tunnel settings");
        if (self.looper.isLinkAttached()) try self.looper.detach(.link);
        const remote = try self.setupLink();
        // Entering rebind transfers a connection-owned link, even on failure.
        if (!try connection.rebind(remote)) return error.UnableToStart;
    }

    fn linkRefreshFailed(self: *ConnectionDaemon, err: anyerror) void {
        log.writef(.err, "Unable to refresh connection link: {s}", .{@errorName(err)});
        self.handleConnectionFailed(.{
            .err_pair = .{ .code = switch (err) {
                error.OutOfMemory => .outOfMemory,
                error.DNSResolutionFailure => .dnsFailure,
                error.Timeout => .timeout,
                else => .ioFailure,
            } },
            .disposition = .reconnect,
        });
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

    fn cancelConnection(self: *ConnectionDaemon, err_pair: ?api.PartoutErrorPair) void {
        self.daemon.enterFailedState();
        self.daemon.controller.setReasserting(false);
        if (!self.daemon.options.cancels_unrecoverable and
            self.daemon.snapshot_publisher.environment.connection_status != .disconnected)
        {
            self.trackConnectionStatus(.disconnected);
        }
        self.daemon.requestCancellation(err_pair, false);
    }

    fn clearConnectionTunnel(self: *ConnectionDaemon) void {
        if (self.connection != null) {
            self.detachLooperSides() catch {};
        }
        self.daemon.controller.clearTunnelSettings(false);
    }

    fn pause(self: *ConnectionDaemon) void {
        self.looper.cancelTimer(&self.resume_gate_timer);
        _ = self.gate.setEnabled(false);
    }

    //#endregion

    //#region Actor thread - I/O callbacks

    // The event loop invokes looper callbacks on the actor thread. They may run
    // protocol work directly; lifecycle events are queued until loopOnce returns.

    fn onLinkRead(ctx: ?*anyopaque, packets: Looper.Packets, sources: ?[]const io.SocketAddress) !Looper.ReadAction {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onLinkRead but no connection");
        return conn.submitPackets(.link, packets, sources);
    }

    fn onLinkFailure(ctx: ?*anyopaque, failure: Looper.Failure) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onLinkFailure but no connection");
        conn.looperFailed(.link, failure);
    }

    fn onTunnelRead(ctx: ?*anyopaque, packets: Looper.Packets, _: ?[]const io.SocketAddress) !Looper.ReadAction {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onTunnelRead but no connection");
        return conn.submitPackets(.tun, packets, null);
    }

    fn onTunnelFailure(ctx: ?*anyopaque, failure: Looper.Failure) void {
        const self: *ConnectionDaemon = @ptrCast(@alignCast(ctx.?));
        const conn = self.connection orelse @panic("onTunnelFailure but no connection");
        conn.looperFailed(.tun, failure);
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

    //#endregion

    //#region Event loop

    // Mailbox messages enter through perform on the event-loop thread.
    // Connection finalization also runs on that thread before it exits.

    const Job = struct {
        command: Command,
        done: bool = false,
        result: Error!void = {},
        next: ?*Job = null,
    };

    const Command = union(enum) {
        message: Message,
        perform: struct {
            context: *anyopaque,
            callback: *const fn (*ConnectionDaemon, *anyopaque) Error!void,
        },
    };

    const Message = union(enum) {
        start,
        hold,
        stop,
        resumeGate,
        onReachability: io.ReachabilityInfo,
        onBetterPath,
        onConnectionEstablished: net.Connection.Events.Success,
        onConnectionNeedsRebind,
        onConnectionFailed: net.Connection.Events.Failure,
        onConnectionStopped,
        onConnectionSetEnvironmentValue: struct {
            key: []const u8,
            value: ?[]const u8,
        },
        onConnectionDataCount: api.DataCount,

        // Accepted deferred messages own their payload until job completion.
        fn deinit(self: Message, allocator: std.mem.Allocator) void {
            switch (self) {
                .onConnectionEstablished => |success| {
                    var info = success.info;
                    info.deinit(allocator);
                },
                .onConnectionSetEnvironmentValue => |update| {
                    allocator.free(update.key);
                    if (update.value) |value| allocator.free(value);
                },
                else => {},
            }
        }
    };

    fn run(self: *ConnectionDaemon) void {
        self.jobs_mutex.lock();
        var running = self.is_running;
        self.actor_id = std.Thread.getCurrentId();
        self.jobs_mutex.unlock();

        // Record event loop terminations caused by the looper.
        var loop_terminated = false;
        var loop_failure: ?io.Failure = null;

        while (running) {
            // Fetch pending jobs if any.
            self.jobs_mutex.lock();
            running = self.is_running;
            _ = io_c.pp_mux_reset_wake(self.mux);
            const maybe_jobs = self.jobs.takeAll();
            self.jobs_mutex.unlock();

            // Drain fetched jobs.
            var pending = maybe_jobs;
            while (pending) |job| {
                pending = job.next;

                // Run jobs if thread is still running.
                const result = if (running) self.executeJob(job.command) else error.Closed;
                result catch |err| {
                    log.writef(.err, "Unable to run job: {s}", .{@errorName(err)});
                };
                running = self.completeJob(job, result);
            }
            if (!running) break;

            // Wait for new jobs or I/O.
            var maybe_failure: ?io.Failure = null;
            const should_loop = self.looper.loopOnce(&maybe_failure);
            if (maybe_failure) |failure| {
                log.writef(.err, "Looper failed: .{}", .{failure});
            }
            // A hard looper failure may also stop the thread.
            if (!should_loop) {
                loop_terminated = true;
                loop_failure = maybe_failure;
                running = false;
            }
        }

        // Signal finalization to close job submissions.
        self.jobs_mutex.lock();
        const unexpected_exit = loop_terminated and self.is_running;
        self.is_running = false;
        var pending = self.jobs.takeAll();
        self.jobs_mutex.unlock();

        // Explicit shutdown must also finalize a connection if stop was not run.
        self.doStop(if (unexpected_exit) .preserve_environment else .clear_environment);

        // Discard outstanding jobs.
        while (pending) |job| {
            pending = job.next;
            _ = self.completeJob(job, error.Closed);
        }

        // Signal unexpected looper failures.
        if (unexpected_exit) self.handleEventLoopFailure(loop_failure);

        self.jobs_mutex.lock();
        self.actor_id = null;
        self.jobs_mutex.unlock();
    }

    fn executeJob(self: *ConnectionDaemon, command: Command) Error!void {
        switch (command) {
            .message => |message| return try self.dispatch(void, message),
            .perform => |request| return request.callback(self, request.context),
        }
    }

    fn completeJob(self: *ConnectionDaemon, job: *Job, result: Error!void) bool {
        self.jobs_mutex.lock();
        const still_running = self.is_running;
        const owned_message: ?Message = switch (job.command) {
            .message => |message| message,
            .perform => null,
        };
        job.result = result;
        job.done = true;
        self.jobs_condition.broadcast();
        self.jobs_mutex.unlock();

        if (owned_message) |message| {
            message.deinit(self.daemon.allocator);
            self.daemon.allocator.destroy(job);
        }
        return still_running;
    }

    fn schedule(self: *ConnectionDaemon, message: Message) !void {
        self.jobs_mutex.lock();
        defer self.jobs_mutex.unlock();
        if (!self.is_running) return error.Closed;

        var job = try self.daemon.allocator.create(Job);
        job.command = .{ .message = message };
        self.jobs.append(job);
        _ = io_c.pp_mux_wake(self.mux);
    }

    fn perform(self: *ConnectionDaemon, comptime Result: type, message: Message) Error!Result {
        const Request = struct {
            message: Message,
            result: Result = undefined,

            fn call(context: *ConnectionDaemon, opaque_request: *anyopaque) Error!void {
                const request: *@This() = @ptrCast(@alignCast(opaque_request));
                request.result = try dispatch(context, Result, request.message);
            }
        };

        self.jobs_mutex.lock();
        if (!self.is_running) {
            self.jobs_mutex.unlock();
            return error.Closed;
        }

        var request = Request{ .message = message };
        var job = Job{ .command = .{ .perform = .{
            .context = &request,
            .callback = Request.call,
        } } };

        // Watch out for recursive locks. If we are invoking perform()
        // on the actor thread, e.g., as the effect of a nested
        // perform(), we must execute the job immediately. Waiting on
        // the condition would lead to a deadlock.
        if (self.isCurrentThread()) {
            self.jobs_mutex.unlock();
            return try self.dispatch(Result, message);
        }
        defer self.jobs_mutex.unlock();

        self.jobs.append(&job);
        _ = io_c.pp_mux_wake(self.mux);
        while (!job.done) {
            self.jobs_condition.wait(&self.jobs_mutex);
        }
        try job.result;
        return request.result;
    }

    fn shutdown(self: *ConnectionDaemon) void {
        self.jobs_mutex.lock();
        defer self.jobs_mutex.unlock();
        if (!self.is_running) return;
        self.is_running = false;
        _ = io_c.pp_mux_wake(self.mux);
    }

    fn dispatch(self: *ConnectionDaemon, comptime Result: type, message: Message) Error!Result {
        switch (message) {
            .start => try self.doStart(),
            .hold => self.doHold(),
            .stop => self.doStop(.clear_environment),
            .resumeGate => self.doResumeGate(),
            .onReachability => |reachability| self.handleReachabilitySignal(reachability),
            .onBetterPath => self.handleBetterPath(),
            .onConnectionEstablished => |success| {
                self.handleConnectionEstablished(success) catch |err| {
                    log.writef(.fault, "Unable to establish connection: {s}", .{@errorName(err)});
                    self.handleConnectionFailed(.{
                        .err_pair = .{ .code = partoutCodeForDaemonStartError(err) },
                        .disposition = .reconnect,
                    });
                };
            },
            .onConnectionNeedsRebind => self.handleConnectionNeedsRebind() catch |err| self.linkRefreshFailed(err),
            .onConnectionFailed => |arg| self.handleConnectionFailed(arg),
            .onConnectionStopped => self.handleConnectionStopped(),
            .onConnectionSetEnvironmentValue => |update| {
                // Finalization can queue a clear while the actor is stopping.
                // Deliver it, but do not restore stale values after shutdown.
                if (self.daemon.state == .started or update.value == null) {
                    self.daemon.controller.setEnvironmentValue(update.key, update.value);
                }
            },
            .onConnectionDataCount => |count| self.daemon.handleDataCount(count),
        }
    }

    fn handleEventLoopFailure(self: *ConnectionDaemon, failure: ?io.Failure) void {
        log.write(.fault, "ConnectionDaemon event loop terminated unexpectedly");
        const err_pair: ?api.PartoutErrorPair = if (partoutCodeForLooperFailure(failure)) |code|
            .{ .code = code }
        else
            null;
        if (err_pair) |err| self.daemon.handleLastError(err);
        self.daemon.controller.setReasserting(false);
        self.daemon.requestCancellation(err_pair, true);
    }

    fn isCurrentThread(self: *const ConnectionDaemon) bool {
        const actor_id = self.actor_id orelse return false;
        return actor_id == std.Thread.getCurrentId();
    }

    //#endregion

};

//#region Error mapping

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
    pub const perform = ConnectionDaemon.perform;
    pub const schedule = ConnectionDaemon.schedule;
    pub const isCurrentThread = ConnectionDaemon.isCurrentThread;
    pub const codeForDaemonStartError = partoutCodeForDaemonStartError;
    pub const codeForLooperFailure = partoutCodeForLooperFailure;

    pub fn shutdown(owner: anytype) void {
        owner.shutdown();
    }

    pub fn evaluateConnection(owner: anytype) Error!void {
        return onLoop(owner, {}, struct {
            fn run(loop: *ConnectionDaemon, _: void) Error!void {
                loop.doEvaluateConnection();
            }
        }.run);
    }

    pub fn resumeGate(owner: anytype) Error!void {
        return owner.perform(void, .resumeGate);
    }

    /// Runs test setup and observations on the same thread as daemon state.
    pub fn onLoop(self: anytype, context: anytype, comptime callback: anytype) Error!void {
        const Request = struct {
            context: @TypeOf(context),
            fn call(owner: *ConnectionDaemon, raw: *anyopaque) Error!void {
                const request: *@This() = @ptrCast(@alignCast(raw));
                return callback(owner, request.context);
            }
        };
        self.jobs_mutex.lock();
        if (self.isCurrentThread()) {
            self.jobs_mutex.unlock();
            return callback(self, context);
        }
        defer self.jobs_mutex.unlock();
        if (!self.is_running) return error.Closed;
        var request = Request{ .context = context };
        var job = ConnectionDaemon.Job{ .command = .{ .perform = .{
            .context = &request,
            .callback = Request.call,
        } } };
        self.jobs.append(&job);
        _ = io_c.pp_mux_wake(self.mux);
        while (!job.done) self.jobs_condition.wait(&self.jobs_mutex);
        return job.result;
    }
};

//#endregion
