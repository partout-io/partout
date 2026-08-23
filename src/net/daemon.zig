// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! The `Daemon` interprets a profile to establish a
//! connection and the tunnel settings that the connection carries
//! on success. It maintains the connection across network events,
//! and forwards better path signals to the connection in case it
//! wants to handle them.
//!
//! The daemon acquires a few objects from the outside:
//!
//! - ConnectionRegistry: To create a connection from a module.
//!
//! The other ones constitute the `Sandbox` that the connection operates in:
//!
//! - `TunnelController`: Applies tunnel settings at the OS level.
//! - `DNSResolver`: Performs DNS resolution.
//! - `SocketFactory`: Creates sockets.
//! - `NetworkMonitor`: Observes network reachability and better path events.
//! - `Looper`: A daemon-owned link/tunnel I/O loop borrowed by the connection.
//!
//! It also creates a `ConnectionGate` to convert network signals into
//! actions to perform on the current connection.
//!
//! Important assumptions for safety:
//!
//! - The daemon must not be used concurrently.
//! - The external callbacks must be serialized with the daemon.
//! - The provided `Context` must remain valid for the daemon lifetime.
//! - The daemon must be stopped before deallocation; `deinit()` assumes
//! no in-flight callbacks and does not synchronize with them.
//!
//! These are additional external guarantees:
//!
//! - Event handlers must not be called past `setEventHandler(null)`.
//! - Connections must not emit further events past `stop()`.
//!
//! These are the entry points that require serialized access to
//! the daemon actor:
//!
//! - Public methods: start, hold, stop
//! - Connection events: status, last error, data count
//! - onNetworkReady(): From `ConnectionGate`
//! - onReachability(): From `NetworkMonitor`, gated through `ConnectionGate`
//! - onBetterPath(): From `NetworkMonitor`, forwarded to current `Connection`

const std = @import("std");

const conn_mod = @import("connection.zig");
const core = @import("../core/exports.zig");
const helpers = @import("daemon_helpers.zig");
const io = @import("io.zig");
const looper_mod = @import("looper.zig");
const sandbox = @import("sandbox.zig");

const api = core.api;
const log = core.logging;
const Connection = conn_mod.Connection;
const ConnectionGate = helpers.ConnectionGate;
const ConnectionRegistry = conn_mod.ConnectionRegistry;
const Looper = looper_mod.Looper;
const SnapshotPublisher = helpers.SnapshotPublisher;
const activeConnectionModule = conn_mod.activeConnectionModule;

pub const Error = api.DecodeError || conn_mod.CreateError || error{
    AlreadyStarted,
    Closed,
    IdGeneration,
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
    const State = enum {
        initial,
        started,
        failed,
        stopping,
        stopped,
    };

    const StopMode = enum {
        clear_environment,
        preserve_environment,
    };

    const ConnectionRuntime = struct {
        connection: Connection,
        looper: *Looper,
    };

    // Input parameters
    allocator: std.mem.Allocator,
    profile: api.Profile,
    registry: *const ConnectionRegistry,
    controller: sandbox.TunnelController,
    resolver: sandbox.DNSResolver,
    factory: sandbox.SocketFactory,
    monitor: sandbox.NetworkMonitor,
    options: Context.Options,

    // Internal state
    actor: *Actor,
    state: State,
    stop_mode: StopMode,
    connection_runtime: ?ConnectionRuntime,
    gate: ?ConnectionGate,
    snapshot_publisher: SnapshotPublisher,
    resume_gate_timer: core.RunAfter,
    is_evaluating_connection: bool,
    cancellation_requested: bool,
    is_deinitializing: bool,

    // Testing only
    test_status_history: [64]api.ConnectionStatus,
    test_status_count: usize,

    pub fn create(
        allocator: std.mem.Allocator,
        original_profile: *const api.Profile,
        context: Context,
    ) Error!*Daemon {
        // Clone profile for safety, then log it.
        var profile = try original_profile.clone(allocator);
        errdefer profile.deinit(allocator);
        log.write(.notice, "Decoded profile:");
        log.writeProfile(.notice, &profile);

        const daemon = try allocator.create(Daemon);
        errdefer allocator.destroy(daemon);
        const actor = Actor.create(allocator, daemon) catch return error.OutOfMemory;

        daemon.* = .{
            .allocator = allocator,
            .actor = actor,
            .profile = profile,
            .registry = context.objects.registry,
            .controller = context.objects.controller,
            .resolver = context.objects.resolver,
            .factory = context.objects.factory,
            .monitor = context.objects.monitor,
            .options = context.options,
            .state = .initial,
            .stop_mode = .clear_environment,
            .connection_runtime = null,
            .gate = null,
            .snapshot_publisher = SnapshotPublisher.init(
                profile.id,
                reportSnapshot,
                daemon,
                context.options.min_data_count_delta,
            ),
            .resume_gate_timer = .{},
            .is_evaluating_connection = false,
            .cancellation_requested = false,
            .is_deinitializing = false,
            .test_status_history = undefined,
            .test_status_count = 0,
        };
        errdefer {
            daemon.is_deinitializing = true;
            actor.destroy();
        }

        if (activeConnectionModule(&profile) != null) {
            daemon.gate = ConnectionGate.init(null);
        }
        return daemon;
    }

    pub fn destroy(self: *Daemon) void {
        // This is crucial to guarantee that there will not be in-flight
        // handlers (reachability, better path, connection events) still calling
        // into the daemon.
        //
        // The daemon must not be deallocated before a full stop, unless it
        // wasn't started in the first place.
        if (self.state != .initial and self.state != .stopped)
            @panic("Daemon.destroy() requires an initial or fully stopped daemon");

        // Also cancels the timer
        self.resume_gate_timer.deinit();

        // Suppress the actor's unexpected-termination path: stop() already
        // dismantled the connection runtime.
        self.is_deinitializing = true;
        self.actor.destroy();

        self.monitor.setEventHandler(null);
        self.monitor.stopObserving();
        if (self.gate) |*gate| {
            gate.stopObserving();
            gate.deinit();
        }
        if (self.connection_runtime != null)
            @panic("Daemon.destroy() cannot release a live connection runtime");
        self.profile.deinit(self.allocator);
        self.allocator.destroy(self);

        log.write(.debug, "Deinit daemon");
    }

    pub fn isConnectionProfile(self: Daemon) bool {
        return activeConnectionModule(&self.profile) != null;
    }

    pub fn isSettingsOnly(self: Daemon) bool {
        return !self.isConnectionProfile();
    }

    // #region Actor interface

    const Actor = core.actor.ActorWithFinish(
        Daemon,
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
        onConnectionStatus: api.ConnectionStatus,
        onConnectionLastError: api.PartoutErrorCode,
        onConnectionDataCount: api.DataCount,
        onConnectionCancel: ?api.PartoutErrorCode,
        onLooperTerminated: ?Looper.Failure,
        recoverConnection,
        onConnectionBlock: struct {
            ptr: *anyopaque,
            block: sandbox.SerializedExecutor.Block,
            discard: ?sandbox.SerializedExecutor.Block,
        },
    };

    fn perform(self: *Daemon, message: Message) Error!void {
        switch (message) {
            .start => try self.doStart(),
            .hold => self.doHold(),
            .stop => self.doStop(.clear_environment),
            .evaluateConnection => self.doEvaluateConnection(),
            .resumeGate => self.doResumeGate(),
            .onReachability => |reachability| self.handleReachabilitySignal(reachability),
            .onBetterPath => self.handleBetterPath(),
            .onConnectionStatus => |status| self.handleConnectionStatus(status),
            .onConnectionLastError => |code| self.handleLastError(code),
            .onConnectionDataCount => |count| self.handleDataCount(count),
            .onConnectionCancel => |code| self.handleConnectionCancel(code),
            .onLooperTerminated => |failure| self.handleLooperTermination(failure),
            .recoverConnection => self.recoverConnectionRuntime(),
            .onConnectionBlock => |payload| self.handleConnectionBlock(
                payload.ptr,
                payload.block,
                payload.discard,
            ),
        }
    }

    pub fn start(self: *const Daemon) Error!void {
        return self.actor.perform(.start);
    }

    pub fn hold(self: *const Daemon) void {
        self.actor.perform(.hold) catch return;
    }

    pub fn stop(self: *const Daemon) void {
        self.actor.perform(.stop) catch return;
    }

    // The ready event gates the signals from:
    //
    // - gate.updateStatus()
    // - gate.updateReachability()
    fn onNetworkReady(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        log.write(.notice, "Network is ready, start connection");
        self.actor.perform(.evaluateConnection) catch |err| {
            log.writef(.err, "Unable to evaluate connection: {s}", .{@errorName(err)});
        };
    }

    // This is scheduled with a delay
    fn onResumeGate(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.actor.perform(.resumeGate) catch |err| {
            log.writef(.err, "Unable to resume connection gate: {s}", .{@errorName(err)});
        };
    }

    // Network callbacks may originate while the platform owns a lock that is
    // also needed by tunnel-controller callbacks. Never wait for the actor
    // here: starting a connection can synchronously report a snapshot back to
    // the platform and would otherwise deadlock with that lock held.
    fn onReachability(ctx: ?*anyopaque, reachability: io.ReachabilityInfo) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.actor.schedule(.{ .onReachability = reachability }) catch |err| {
            log.writef(.err, "Unable to enqueue reachability: {s}", .{@errorName(err)});
        };
    }

    // Like reachability, better-path notifications come from platform code
    // whose locks must be released before calling back into the controller.
    fn onBetterPath(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.actor.schedule(.onBetterPath) catch |err| {
            log.writef(.err, "Unable to enqueue better path: {s}", .{@errorName(err)});
        };
    }

    // This is where connection events are rerouted through the actor
    fn events(self: *Daemon) Connection.Events {
        return .{
            .ctx = self,
            .status = onConnectionStatus,
            .last_error = onConnectionLastError,
            .data_count = onConnectionDataCount,
            .cancel = onConnectionCancel,
        };
    }

    // Provides a way for the connection to run code on the daemon actor
    fn serializedExecutor(self: *Daemon) sandbox.SerializedExecutor {
        return .{
            .ptr = self,
            .run_block = onConnectionBlock,
        };
    }

    fn onConnectionStatus(ctx: *anyopaque, status: api.ConnectionStatus) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.actor.perform(.{ .onConnectionStatus = status }) catch |err| {
            log.writef(.err, "Unable to report connection status: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionLastError(ctx: *anyopaque, code: api.PartoutErrorCode) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.actor.perform(.{ .onConnectionLastError = code }) catch |err| {
            log.writef(.err, "Unable to report connection last error: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionDataCount(ctx: *anyopaque, data_count: api.DataCount) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.actor.perform(.{ .onConnectionDataCount = data_count }) catch |err| {
            log.writef(.err, "Unable to report connection data count: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionCancel(ctx: *anyopaque, code: ?api.PartoutErrorCode) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.actor.perform(.{ .onConnectionCancel = code }) catch |err| {
            log.writef(.err, "Unable to request connection cancellation: {s}", .{@errorName(err)});
        };
    }

    fn onConnectionBlock(
        ctx: *anyopaque,
        ptr: *anyopaque,
        block: sandbox.SerializedExecutor.Block,
        discard: ?sandbox.SerializedExecutor.Block,
    ) sandbox.SerializedExecutor.RunError!void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        // RunAfter callbacks must return without waiting for the actor. This
        // lets cancellation drain a callback even when stop currently owns the
        // actor, and preserves FIFO ordering with a later restart.
        try self.actor.schedule(.{ .onConnectionBlock = .{
            .ptr = ptr,
            .block = block,
            .discard = discard,
        } });
    }

    // #endregion

    // #region Actor handlers

    fn doStart(self: *Daemon) Error!void {
        if (self.state != .initial) return error.AlreadyStarted;
        if (self.isConnectionProfile()) try self.initConnectionRuntime();
        self.state = .started;

        log.write(.notice, "Start daemon");
        self.clearEnvironment();

        // Establish settings-only tunnel if no connection
        if (self.isSettingsOnly()) {
            var maybe_info = buildSettingsOnlyTunnelInfo(self.allocator, &self.profile) catch |err| {
                self.handleStartError(err);
                return;
            };
            if (maybe_info) |*info| {
                defer info.deinit(self.allocator);
                _ = self.controller.setTunnelSettings(info.*) catch |err| {
                    self.handleStartError(err);
                    return;
                };
            }
            log.write(.notice, "Daemon started successfully");
            return;
        }

        // Start .disconnected
        self.emitStatus(.disconnected);

        // Bind the connection gate
        if (self.gate) |*gate| {
            // Notify reachability to the connection gate
            self.monitor.setEventHandler(.{
                .ptr = self,
                .on_reachability = onReachability,
                .on_better_path = onBetterPath,
            });
            // Notify connection gate ready to the daemon
            gate.setReadyHandler(.{
                .ptr = self,
                .notify = onNetworkReady,
            });
            // Read current reachability
            gate.setReachabilityBlock(.{
                .ptr = self,
                .is_reachable = isReachable,
            });

            self.monitor.startObserving();
            gate.startObserving();
            _ = gate.updateStatus(.disconnected);
        }
        log.write(.notice, "Daemon started successfully");

        // Start a connection now, or defer the choice to the gate
        if (self.options.starts_immediately) {
            self.startConnection();
        } else {
            if (self.gate) |*gate| {
                _ = gate.setEnabled(true);
            }
        }
    }

    fn handleStartError(self: *Daemon, err: StartError) void {
        log.writef(.fault, "Unable to start daemon: {s}", .{@errorName(err)});
        const code = partoutCodeForDaemonStartError(err);
        self.handleLastError(code);
        self.controller.setReasserting(false);
        self.requestCancellation(code, false);
    }

    fn doHold(self: *Daemon) void {
        self.doStop(.preserve_environment);
    }

    fn doStop(self: *Daemon, mode: StopMode) void {
        switch (self.state) {
            .stopping => {
                // A reentrant hold may upgrade an in-progress normal stop.
                if (mode == .preserve_environment) self.stop_mode = mode;
                return;
            },
            .stopped => return,
            .initial, .started, .failed => {},
        }
        self.stop_mode = mode;
        self.state = .stopping;

        log.write(.notice, "Stop daemon");
        self.resume_gate_timer.cancel();

        self.monitor.setEventHandler(null);
        self.monitor.stopObserving();

        if (self.gate) |*gate| {
            gate.setReachabilityBlock(null);
            gate.stopObserving();
        }

        // Settings-only, stop immediately
        if (self.isSettingsOnly()) {
            log.write(.notice, "Non-connection profile, nothing to disconnect from");
            self.controller.clearTunnelSettings(false);
            self.finishStop();
            return;
        }

        // Otherwise, complete stop after connection stops
        log.writef(.notice, "Connection profile, disconnect with a timeout of {} milliseconds", .{
            self.options.stop_delay_ms,
        });
        const runtime = self.connection_runtime orelse {
            self.finishStop();
            return;
        };
        runtime.connection.stop(self.options.stop_delay_ms, self.events());
        self.deinitConnectionRuntime();
        self.finishStop();
    }

    fn finishStop(self: *Daemon) void {
        self.state = .stopped;
        if (self.stop_mode == .clear_environment) self.clearEnvironment();
        log.write(.notice, "Daemon stopped successfully");
    }

    fn startConnection(self: *Daemon) void {
        self.internalEvaluateConnection(true);
    }

    fn doEvaluateConnection(self: *Daemon) void {
        self.internalEvaluateConnection(false);
    }

    fn internalEvaluateConnection(self: *Daemon, force: bool) void {
        if (self.state != .started) {
            log.write(.info, "Ignore evaluation, daemon not started");
            return;
        }
        const runtime = self.connection_runtime orelse return;
        const conn = runtime.connection;
        if (self.is_evaluating_connection) {
            log.write(.debug, "Ignore evaluation, another one pending");
            return;
        }

        self.is_evaluating_connection = true;
        defer self.is_evaluating_connection = false;

        if (!force and !self.monitor.isReachable()) {
            log.write(.info, "Ignore evaluation, wait for reachable network");
            if (self.gate) |*gate| {
                _ = gate.setEnabled(true);
            }
            return;
        }

        log.write(.info, "Pause connection gate during reconnection");
        if (self.gate) |*gate| {
            _ = gate.setEnabled(false);
        }

        log.write(.notice, "Start connection");
        const did_start = conn.start(self.events()) catch |err| {
            log.writef(.err, "Unable to start connection: {s}", .{@errorName(err)});
            const code = partoutCodeForDaemonStartError(err);
            self.handleLastError(code);
            self.controller.setReasserting(false);
            return;
        };
        if (!did_start) {
            log.write(.err, "Connection still active");
            self.scheduleResumeGate();
        }
    }

    fn scheduleResumeGate(self: *Daemon) void {
        if (self.state != .started) {
            log.write(.info, "Ignore resume connection gate, daemon not started");
            return;
        }
        const delay_ms = self.options.reconnection_delay_ms;
        log.writef(.info, "Resume connection gate in {} milliseconds", .{delay_ms});

        // Contextually cancels the previous attempt
        self.resume_gate_timer.scheduleReplacing(delay_ms, onResumeGate, self) catch |err| {
            log.writef(.err, "Unable to schedule resume connection gate, resume now: {s}", .{@errorName(err)});
            self.doResumeGate();
        };
    }

    fn doResumeGate(self: *Daemon) void {
        if (self.state != .started) {
            log.write(.info, "Ignore resume connection gate, daemon not started");
            return;
        }
        log.write(.info, "Resume connection gate now");
        if (self.gate) |*gate| {
            _ = gate.setEnabled(true);
        }
    }

    // Updates the gate on the actor so that a ready transition and the
    // resulting connection start are serialized with the corresponding
    // network-change event.
    fn handleReachabilitySignal(self: *Daemon, reachability: io.ReachabilityInfo) void {
        if (self.gate) |*gate| {
            _ = gate.updateReachability(reachability.reachable);
        }
        self.handleReachability(reachability);
    }

    // Forwards the event to the underlying connection
    fn handleReachability(self: *Daemon, reachability: io.ReachabilityInfo) void {
        if (self.state != .started) return;
        const runtime = self.connection_runtime orelse return;
        const conn = runtime.connection;
        conn.networkChange(reachability, self.events());
    }

    // Forwards the event to the underlying connection
    fn handleBetterPath(self: *Daemon) void {
        if (self.state != .started) return;
        const runtime = self.connection_runtime orelse return;
        const conn = runtime.connection;
        conn.betterPath(self.events());
    }

    fn handleConnectionStatus(self: *Daemon, status: api.ConnectionStatus) void {
        self.snapshot_publisher.setConnectionStatus(status);
        switch (status) {
            .connected => self.controller.setReasserting(false),
            .connecting => {
                self.emitRemove(.last_error_code);
                self.snapshot_publisher.setLastError(null);
                self.controller.setReasserting(true);
            },
            .disconnecting => {},
            .disconnected => {
                self.resetDataCount();
                self.controller.setReasserting(false);
                self.scheduleResumeGate();
            },
        }
        self.emitStatus(status);
        self.snapshot_publisher.publishCurrentSnapshot(true);
        if (self.gate) |*gate| {
            _ = gate.updateStatus(status);
        }
    }

    fn handleLastError(self: *Daemon, code: api.PartoutErrorCode) void {
        self.resetDataCount();
        self.snapshot_publisher.setLastError(code);
        self.snapshot_publisher.publishCurrentSnapshot(true);
        if (self.options.events) |e| e.last_error(e.ctx, code);
    }

    fn handleDataCount(self: *Daemon, data_count: api.DataCount) void {
        self.snapshot_publisher.setDataCount(data_count);
        self.snapshot_publisher.publishCurrentSnapshot(false);
        if (self.options.events) |e| e.data_count(e.ctx, data_count);
    }

    fn handleConnectionCancel(self: *Daemon, code: ?api.PartoutErrorCode) void {
        self.enterFailedState();
        self.controller.setReasserting(false);
        if (!self.options.cancels_unrecoverable and
            self.snapshot_publisher.environment.connection_status != .disconnected)
        {
            self.handleConnectionStatus(.disconnected);
        }
        self.requestCancellation(code, false);
    }

    fn resetDataCount(self: *Daemon) void {
        self.snapshot_publisher.setDataCount(.{});
        self.emitRemove(.data_count);
    }

    fn handleLooperTermination(
        self: *Daemon,
        failure: ?Looper.Failure,
    ) void {
        if (self.state != .started) return;

        log.write(.fault, "Daemon-owned looper terminated");

        if (partoutCodeForLooperFailure(failure)) |code| {
            self.handleLastError(code);
        }

        // The looper terminal callback already stopped protocol producers and
        // released their queue-confined state. Finalize the connection before
        // replacing the daemon-owned runtime.
        if (self.connection_runtime) |runtime| {
            runtime.connection.stop(0, self.events());
        }
        self.resume_gate_timer.cancel();
        self.actor.schedule(.recoverConnection) catch |err| {
            log.writef(.fault, "Unable to schedule connection recovery: {s}", .{@errorName(err)});
            self.controller.setReasserting(false);
            self.requestCancellation(partoutCodeForLooperFailure(failure), true);
        };
    }

    fn requestCancellation(
        self: *Daemon,
        code: ?api.PartoutErrorCode,
        force: bool,
    ) void {
        self.enterFailedState();
        if (self.cancellation_requested) return;
        if (!force and !self.options.cancels_unrecoverable) return;
        self.cancellation_requested = true;
        self.controller.cancelTunnelConnection(code);
    }

    fn enterFailedState(self: *Daemon) void {
        if (self.state != .started) return;
        self.state = .failed;
        self.resume_gate_timer.cancel();
        if (self.gate) |*gate| {
            _ = gate.setEnabled(false);
        }
    }

    fn actorDidFinish(self: *Daemon) void {
        if (self.is_deinitializing) return;

        log.write(.fault, "Daemon actor terminated");

        // The callback still runs on the actor thread, so it can complete the
        // normal serialized stop before the worker exits. The host cancellation
        // then owns final Daemon/Looper deinitialization.
        self.doStop(.preserve_environment);
        self.controller.setReasserting(false);
        self.requestCancellation(null, true);
    }

    fn handleConnectionBlock(
        self: *const Daemon,
        ptr: *anyopaque,
        block: sandbox.SerializedExecutor.Block,
        discard: ?sandbox.SerializedExecutor.Block,
    ) void {
        // A timer may have elapsed just before stop cancelled it. Dropping the
        // queued task here prevents stale work from touching a stopped
        // connection while still allowing the timer thread to drain normally.
        if (self.state != .started) {
            if (discard) |callback| callback(ptr);
            return;
        }
        block(ptr);
    }

    // #endregion

    // #region Emit events (to caller)

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

    // #endregion

    // #region Internal callbacks

    fn isReachable(ctx: ?*const anyopaque) bool {
        const self: *const Daemon = @ptrCast(@alignCast(ctx.?));
        return self.monitor.isReachable();
    }

    fn reportSnapshot(ctx: ?*const anyopaque, snapshot: api.TunnelSnapshot) void {
        const self: *const Daemon = @ptrCast(@alignCast(ctx.?));
        self.controller.reportSnapshot(snapshot);
    }

    fn initConnectionRuntime(self: *Daemon) Error!void {
        if (self.connection_runtime != null)
            @panic("Cannot initialize a second daemon connection runtime");
        const module = activeConnectionModule(&self.profile) orelse return;

        const looper = try self.allocator.create(Looper);
        errdefer self.allocator.destroy(looper);
        looper.* = Looper.init(self.allocator, .{
            .on_finish = .{
                .context = self,
                .callback = onLooperTerminate,
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MuxFailure => return error.LooperFailure,
        };
        errdefer looper.deinit();

        const sb: sandbox.Sandbox = .{
            .profile = &self.profile,
            .controller = self.controller,
            .factory = self.factory,
            .resolver = self.resolver,
            .looper = looper,
            .cache_dir = self.options.cache_dir,
            .serialized_executor = self.serializedExecutor(),
            .options = self.options.connection_options,
        };
        const connection = try self.registry.createConnection(
            self.allocator,
            module,
            sb,
        );
        errdefer connection.destroy();

        // Publish a complete runtime before the looper can invoke its
        // terminal callback.
        self.connection_runtime = .{
            .connection = connection,
            .looper = looper,
        };
        looper.start() catch |err| {
            self.connection_runtime = null;
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.LooperFailure,
            };
        };
    }

    fn recoverConnectionRuntime(self: *Daemon) void {
        if (self.state != .started) return;

        log.write(.notice, "Replace connection after terminal looper");
        self.deinitConnectionRuntime();
        self.initConnectionRuntime() catch |err| {
            log.writef(.fault, "Unable to replace connection: {s}", .{@errorName(err)});
            const code = partoutCodeForDaemonStartError(err);
            self.handleLastError(code);
            self.controller.setReasserting(false);
            self.requestCancellation(code, true);
            return;
        };

        if (self.state == .started) {
            self.startConnection();
        }
    }

    fn deinitConnectionRuntime(self: *Daemon) void {
        const runtime = self.connection_runtime orelse return;

        // Keep the borrowed looper object alive until the connection has
        // released every Session that refers to it, but first join its worker
        // so the terminal callback cannot race connection deinitialization.
        runtime.looper.stop() catch |err| {
            log.writef(.debug, "Unable to stop connection looper: {s}", .{@errorName(err)});
        };
        runtime.connection.destroy();
        runtime.looper.deinit();
        self.allocator.destroy(runtime.looper);
        self.connection_runtime = null;
    }

    fn onLooperTerminate(
        ctx: ?*anyopaque,
        failure: ?Looper.Failure,
    ) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (self.connection_runtime) |runtime| {
            // Protocol cleanup must stay on the terminating looper queue.
            // Lifecycle policy remains on the daemon actor below.
            runtime.connection.looperTerminated(failure);
        }
        self.actor.schedule(.{ .onLooperTerminated = failure }) catch |err| {
            log.writef(.debug, "Ignore terminal looper after actor shutdown: {s}", .{@errorName(err)});
        };
    }

    // #endregion

    // #region Testing

    pub fn testStatuses(self: *const Daemon) []const api.ConnectionStatus {
        return self.test_status_history[0..self.test_status_count];
    }

    fn publishTestStatus(self: *Daemon, status: api.ConnectionStatus) void {
        if (self.test_status_count < self.test_status_history.len) {
            self.test_status_history[self.test_status_count] = status;
            self.test_status_count += 1;
        }
    }

    // #endregion
};

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

// MARK: - Error mapping

fn partoutCodeForDaemonStartError(_: StartError) api.PartoutErrorCode {
    // FIXME: ###, Map ??? to PartoutErrorCode
    return .unhandled;
}

fn partoutCodeForLooperFailure(opt_failure: ?Looper.Failure) ?api.PartoutErrorCode {
    const failure = opt_failure orelse return null;
    // FIXME: ###, Map Looper.Failure to PartoutErrorCode
    _ = failure;
    return .unhandled;
}
