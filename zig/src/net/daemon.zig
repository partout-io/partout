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
const sandbox = @import("sandbox.zig");

const api = core.api;
const log = core.logging;
const Connection = conn_mod.Connection;
const ConnectionGate = helpers.ConnectionGate;
const ConnectionRegistry = conn_mod.ConnectionRegistry;
const SnapshotPublisher = helpers.SnapshotPublisher;
const activeConnectionModule = conn_mod.activeConnectionModule;

pub const Error = api.DecodeError || conn_mod.CreateError || error{
    AlreadyStarted,
    Closed,
    IdGeneration,
    InvalidProfile,
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
        events: ?Connection.Events = null,
        connection_options: sandbox.ConnectionOptions = .{},
    };

    objects: Objects,
    options: Options,
};

pub const Daemon = struct {
    const State = enum {
        initial,
        started,
        stopping,
        stopped,
    };

    // Input parameters
    profile: api.Profile,
    controller: sandbox.TunnelController,
    monitor: sandbox.NetworkMonitor,
    options: Context.Options,

    // Internal state
    actor: *Actor,
    state: State = .initial,
    connection: ?Connection = null,
    gate: ?ConnectionGate = null,
    snapshot_publisher: SnapshotPublisher,
    resume_gate_timer: core.RunAfter = .{},
    is_evaluating_connection: bool = false,
    on_hold: bool = false,

    // Testing only
    test_status_history: [64]api.ConnectionStatus = undefined,
    test_status_count: usize = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        original_profile: api.Profile,
        context: Context,
    ) Error!*Daemon {
        // Clone profile for safety, then log it
        var profile = try original_profile.clone(allocator);
        errdefer profile.deinit(allocator);
        api.logDecodedProfile(allocator, profile);

        const daemon = try allocator.create(Daemon);
        errdefer allocator.destroy(daemon);
        const actor = Actor.create(allocator, daemon) catch return error.OutOfMemory;
        errdefer actor.deinit();

        daemon.* = .{
            .actor = actor,
            .profile = profile,
            .controller = context.objects.controller,
            .monitor = context.objects.monitor,
            .options = context.options,
            .snapshot_publisher = SnapshotPublisher.init(
                profile.id,
                reportSnapshot,
                daemon,
                context.options.min_data_count_delta,
            ),
        };

        // The connection sandbox contains an actor-backed executor whose
        // context is this daemon. Allocate and initialize the stable daemon
        // address before constructing the connection that retains it.
        if (activeConnectionModule(profile)) |module| {
            const sb: sandbox.Sandbox = .{
                .profile = &daemon.profile,
                .controller = context.objects.controller,
                .factory = context.objects.factory,
                .resolver = context.objects.resolver,
                .monitor = context.objects.monitor,
                .serialized_executor = daemon.serializedExecutor(),
                .options = context.options.connection_options,
            };
            daemon.connection = try context.objects.registry.createConnection(allocator, module, sb);
            daemon.gate = ConnectionGate.init(null);
        }
        return daemon;
    }

    pub fn deinit(self: *Daemon, allocator: std.mem.Allocator) void {
        // This is crucial to guarantee that there will not be in-flight
        // handlers (reachability, better path, connection events) still calling
        // into the daemon.
        //
        // The daemon must not be deallocated before a full stop, unless it
        // wasn't started in the first place.
        std.debug.assert(self.state == .initial or self.state == .stopped);

        // Also cancels the timer
        self.resume_gate_timer.deinit();

        // Also shuts down the actor
        self.actor.deinit();

        self.monitor.setEventHandler(null);
        self.monitor.stopObserving();
        if (self.gate) |*gate| {
            gate.stopObserving();
            gate.deinit();
        }
        if (self.connection) |conn| {
            conn.deinit(allocator);
            self.connection = null;
        }
        self.profile.deinit(allocator);
        allocator.destroy(self);

        log.write(.debug, "Deinit daemon");
    }

    // This is safe because connection is not modified
    // during the daemon lifecycle
    pub fn isConnectionProfile(self: Daemon) bool {
        return self.connection != null;
    }

    pub fn isSettingsOnly(self: Daemon) bool {
        return !self.isConnectionProfile();
    }

    // #region Actor interface

    const Actor = core.Actor(
        Daemon,
        Message,
        Error,
        perform,
    );

    const Message = union(enum) {
        start: struct {
            allocator: std.mem.Allocator,
        },
        hold,
        stop,
        evaluateConnection,
        resumeGate,
        onReachability: io.ReachabilityInfo,
        onBetterPath,
        onConnectionStatus: api.ConnectionStatus,
        onConnectionLastError: api.PartoutErrorCode,
        onConnectionDataCount: api.DataCount,
        onConnectionBlock: struct {
            ptr: *anyopaque,
            block: sandbox.SerializedExecutor.Block,
        },
    };

    fn perform(self: *Daemon, message: Message) Error!void {
        switch (message) {
            .start => |payload| try self.doStart(payload.allocator),
            .hold => self.doHold(),
            .stop => self.doStop(),
            .evaluateConnection => self.doEvaluateConnection(),
            .resumeGate => self.doResumeGate(),
            .onReachability => |reachability| self.handleReachability(reachability),
            .onBetterPath => self.handleBetterPath(),
            .onConnectionStatus => |status| self.handleConnectionStatus(status),
            .onConnectionLastError => |code| self.handleLastError(code),
            .onConnectionDataCount => |count| self.handleDataCount(count),
            .onConnectionBlock => |payload| self.handleConnectionBlock(payload.ptr, payload.block),
        }
    }

    pub fn start(
        self: *Daemon,
        allocator: std.mem.Allocator,
    ) Error!void {
        return self.actor.perform(.{ .start = .{
            .allocator = allocator,
        } });
    }

    pub fn hold(self: *Daemon) void {
        self.actor.perform(.hold) catch return;
    }

    pub fn stop(self: *Daemon) void {
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
            log.writef(.err, "Unable to evaluate connection: {}", .{err});
        };
    }

    // This is scheduled with a delay
    fn onResumeGate(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.actor.perform(.resumeGate) catch |err| {
            log.writef(.err, "Unable to resume connection gate: {}", .{err});
        };
    }

    // This is external and is gated through ConnectionGate
    fn onReachability(ctx: ?*anyopaque, reachability: io.ReachabilityInfo) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (self.gate) |*gate| {
            _ = gate.updateReachability(reachability.reachable);
        }
        self.actor.perform(.{ .onReachability = reachability }) catch |err| {
            log.writef(.err, "Unable to handle reachability: {}", .{err});
        };
    }

    // This is external and is invoked by ConnectionGate
    fn onBetterPath(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.actor.perform(.onBetterPath) catch |err| {
            log.writef(.err, "Unable to handle better path: {}", .{err});
        };
    }

    // This is where connection events are rerouted through the actor
    fn events(self: *Daemon) Connection.Events {
        return .{
            .ctx = self,
            .status = onConnectionStatus,
            .last_error = onConnectionLastError,
            .data_count = onConnectionDataCount,
            .remove_key = onConnectionRemoveKey,
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
            log.writef(.err, "Unable to report connection status: {}", .{err});
        };
    }

    fn onConnectionLastError(ctx: *anyopaque, code: api.PartoutErrorCode) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.actor.perform(.{ .onConnectionLastError = code }) catch |err| {
            log.writef(.err, "Unable to report connection last error: {}", .{err});
        };
    }

    fn onConnectionDataCount(ctx: *anyopaque, data_count: api.DataCount) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.actor.perform(.{ .onConnectionDataCount = data_count }) catch |err| {
            log.writef(.err, "Unable to report connection data count: {}", .{err});
        };
    }

    fn onConnectionRemoveKey(_: *anyopaque, _: conn_mod.Connection.EventKey) void {}

    fn onConnectionBlock(
        ctx: ?*anyopaque,
        ptr: *anyopaque,
        block: sandbox.SerializedExecutor.Block,
    ) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        // RunAfter callbacks must return without waiting for the actor. This
        // lets cancellation drain a callback even when stop currently owns the
        // actor, and preserves FIFO ordering with a later restart.
        self.actor.schedule(.{ .onConnectionBlock = .{
            .ptr = ptr,
            .block = block,
        } }) catch |err| {
            log.writef(.err, "Unable to enqueue serialized connection work: {}", .{err});
        };
    }

    // #endregion

    // #region Actor handlers

    fn doStart(
        self: *Daemon,
        allocator: std.mem.Allocator,
    ) Error!void {
        if (self.state != .initial) return error.AlreadyStarted;
        self.state = .started;

        log.write(.notice, "Start daemon");
        self.clearEvents();

        // Establish settings-only tunnel if no connection
        if (self.connection == null) {
            var maybe_info = buildSettingsOnlyTunnelInfo(allocator, self.profile) catch |err| {
                self.handleStartError(err);
                return;
            };
            if (maybe_info) |*info| {
                defer info.deinit(allocator);
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

    fn handleStartError(self: *Daemon, err: anyerror) void {
        log.writef(.fault, "Unable to start daemon: {}", .{err});
        const code = api.codeForError(err);
        self.handleLastError(code);
        self.controller.setReasserting(false);
        if (self.options.cancels_unrecoverable) {
            self.controller.cancelTunnelConnection(code);
        }
    }

    fn doHold(self: *Daemon) void {
        if (self.on_hold) return;
        self.on_hold = true;
        self.doStop();
    }

    fn doStop(self: *Daemon) void {
        switch (self.state) {
            .stopping => return,
            .stopped => return,
            .initial, .started => {},
        }
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
        if (self.connection == null) {
            log.write(.notice, "Non-connection profile, nothing to disconnect from");
            self.controller.clearTunnelSettings(false);
            self.finishStop();
            return;
        }

        // Otherwise, complete stop after connection stops
        log.writef(.notice, "Connection profile, disconnect with a timeout of {} milliseconds", .{
            self.options.stop_delay_ms,
        });
        self.connection.?.stop(self.options.stop_delay_ms, self.events());
        self.finishStop();
    }

    fn finishStop(self: *Daemon) void {
        self.state = .stopped;
        self.clearEvents();
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
        const conn = self.connection orelse return;
        if (self.is_evaluating_connection) {
            log.write(.debug, "Ignore evaluation, another one pending");
            return;
        }

        self.is_evaluating_connection = true;
        defer self.is_evaluating_connection = false;

        if (self.on_hold) {
            log.write(.info, "Ignore evaluation, daemon on hold");
            return;
        }

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
            log.writef(.err, "Unable to start connection: {}", .{err});
            const code = api.codeForError(err);
            self.handleLastError(code);
            self.controller.setReasserting(false);
            if (self.options.cancels_unrecoverable) {
                self.controller.cancelTunnelConnection(code);
            }
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
        if (self.on_hold) {
            log.write(.info, "Ignore resume connection gate, daemon on hold");
            return;
        }

        const delay_ms = self.options.reconnection_delay_ms;
        log.writef(.info, "Resume connection gate in {} milliseconds", .{delay_ms});

        // Contextually cancels the previous attempt
        self.resume_gate_timer.init(delay_ms, onResumeGate, self) catch |err| {
            log.writef(.err, "Unable to schedule resume connection gate, resume now: {}", .{err});
            self.doResumeGate();
        };
    }

    fn doResumeGate(self: *Daemon) void {
        if (self.state != .started) {
            log.write(.info, "Ignore resume connection gate, daemon not started");
            return;
        }
        if (self.on_hold) {
            log.write(.info, "Ignore resume connection gate, daemon on hold");
            return;
        }
        log.write(.info, "Resume connection gate now");
        if (self.gate) |*gate| {
            _ = gate.setEnabled(true);
        }
    }

    // Forwards the event to the underlying connection
    fn handleReachability(self: *Daemon, reachability: io.ReachabilityInfo) void {
        if (self.state != .started) return;
        const conn = self.connection orelse return;
        conn.networkChange(reachability, self.events());
    }

    // Forwards the event to the underlying connection
    fn handleBetterPath(self: *Daemon) void {
        if (self.state != .started) return;
        const conn = self.connection orelse return;
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
        self.snapshot_publisher.setLastError(code);
        self.snapshot_publisher.publishCurrentSnapshot(true);
        if (self.options.events) |e| e.last_error(e.ctx, code);
    }

    fn handleDataCount(self: *Daemon, data_count: api.DataCount) void {
        self.snapshot_publisher.setDataCount(data_count);
        self.snapshot_publisher.publishCurrentSnapshot(false);
        if (self.options.events) |e| e.data_count(e.ctx, data_count);
    }

    fn handleConnectionBlock(
        self: *Daemon,
        ptr: *anyopaque,
        block: sandbox.SerializedExecutor.Block,
    ) void {
        // A timer may have elapsed just before stop cancelled it. Dropping the
        // queued task here prevents stale work from touching a stopped
        // connection while still allowing the timer thread to drain normally.
        if (self.state != .started) return;
        block(ptr);
    }

    // #endregion

    // #region Emit events (to caller)

    fn emitStatus(self: *Daemon, status: api.ConnectionStatus) void {
        self.publishTestStatus(status);
        if (self.options.events) |e| e.status(e.ctx, status);
    }

    fn emitRemove(self: *Daemon, key: conn_mod.Connection.EventKey) void {
        if (self.options.events) |e| e.remove_key(e.ctx, key);
    }

    fn clearEvents(self: *Daemon) void {
        if (self.on_hold) return;
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
    profile: api.Profile,
) !?api.TunnelRemoteInfoWrapper {
    var modules: std.ArrayList(api.TaggedModule) = .empty;
    defer modules.deinit(allocator);

    for (profile.modules) |module| {
        if (!api.isActiveProfileModule(profile, api.moduleId(&module))) continue;
        if (api.typeBuildsConnection(api.moduleType(&module))) continue;
        try modules.append(allocator, module);
    }

    if (modules.items.len == 0) {
        return null;
    }

    const info = api.TunnelRemoteInfoWrapper{
        .profile = profile,
        .original_module_id = api.moduleId(&modules.items[0]),
        .requires_virtual_device = false,
        .modules = modules.items,
    };
    return try info.clone(allocator);
}
