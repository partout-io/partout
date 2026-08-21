// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const configuration_mod = @import("internal/configuration.zig");
const constants_mod = @import("internal/constants.zig");
const crypto_mod = @import("internal/crypto.zig");
const endpoint_resolver_mod = @import("internal/endpoint_resolver.zig");
const errors_mod = @import("internal/errors.zig");
const logging_mod = @import("internal/logging.zig");
const session_mod = @import("internal/session.zig");
const settings_mod = @import("internal/settings.zig");

const api = core.api;
const log = core.logging;
const openvpn_log = logging_mod;
const EndpointResolver = endpoint_resolver_mod.EndpointResolver;
const SessionOptions = configuration_mod.SessionOptions;
const NetworkSettingsBuilder = settings_mod.NetworkSettingsBuilder;
const PRNG = crypto_mod.PRNG;
const Session = session_mod.Session;
const SessionEvents = session_mod.SessionEvents;
const SessionError = errors_mod.SessionError;
const TLSConstants = constants_mod.TLS;

const EnvironmentKeys = struct {
    const server_configuration = "OpenVPN.serverConfiguration";
};

pub fn createConnection(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: net.ConnectionModule,
    sandbox: net.Sandbox,
) net.ConnectionCreateError!net.Connection {
    const raw = ptr orelse return error.MissingConnectionImplementation;
    const context: *const ConnectionContext = @ptrCast(@alignCast(raw));
    return OpenVPNConnection.create(allocator, context, module, sandbox);
}

/// Inputs selected by the OpenVPN module implementation.
pub const ConnectionContext = struct {
    session_options: SessionOptions = .{},
};

pub const testing = struct {
    pub const codeForTunnelError = tunnelErrorCode;
    pub const isRecoverableSessionError = isRecoverable;
};

const OpenVPNConnection = struct {
    allocator: std.mem.Allocator,
    module_id: api.UUID,
    profile: *const api.Profile,
    controller: net.TunnelController,
    resolver: net.DNSResolver,
    factory: net.SocketFactory,
    looper: *net.Looper,
    serialized_executor: net.SerializedExecutor,
    connection_options: net.ConnectionOptions,
    session_options: SessionOptions,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    endpoints: []api.ExtendedEndpoint,
    endpoint_resolver: EndpointResolver,
    cache_dir: []u8,

    status: api.ConnectionStatus,
    events: ?net.Connection.Events,
    current_session: ?*Session,
    current_endpoint: ?api.ExtendedEndpoint,
    tunnel: ?net.TunWrapper,

    // MARK: - Public API

    fn create(
        allocator: std.mem.Allocator,
        context: *const ConnectionContext,
        module: net.ConnectionModule,
        sandbox: net.Sandbox,
    ) net.ConnectionCreateError!net.Connection {
        const openvpn = switch (module.module.*) {
            .OpenVPN => |*value| value,
            else => return error.MissingConnectionImplementation,
        };
        const source_configuration = if (openvpn.configuration) |*value|
            value
        else
            return error.IncompleteModule;
        var configuration = try configuration_mod.applyingActiveModules(
            allocator,
            source_configuration,
            sandbox.profile,
        );
        errdefer configuration.deinit(allocator);
        configuration_mod.validate(&configuration) catch
            return error.IncompleteModule;

        const maybe_endpoints = configuration_mod.processedRemotes(
            allocator,
            &configuration,
            PRNG.system(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CryptoFailure => return error.IdGeneration,
        };
        const endpoints = maybe_endpoints orelse return error.IncompleteModule;
        errdefer core.util.freeSlice(api.ExtendedEndpoint, allocator, endpoints);
        if (endpoints.len == 0) return error.IncompleteModule;

        var credentials = if (openvpn.credentials) |value|
            value.clone(allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidJson,
                error.InvalidModel,
                error.UnsupportedModel,
                => return error.IncompleteModule,
            }
        else
            null;
        errdefer if (credentials) |*value| value.deinit(allocator);

        const cache_dir = try allocator.dupe(u8, sandbox.cache_dir);
        errdefer allocator.free(cache_dir);

        const created = try allocator.create(OpenVPNConnection);
        var session_options = context.session_options;
        session_options.write_timeout_ms = sandbox.options.link_write_timeout;
        session_options.min_data_count_interval_ms =
            sandbox.options.min_data_count_interval;
        created.* = .{
            .allocator = allocator,
            .module_id = module.id(),
            .profile = sandbox.profile,
            .controller = sandbox.controller,
            .resolver = sandbox.resolver,
            .factory = sandbox.factory,
            .looper = sandbox.looper,
            .serialized_executor = sandbox.serialized_executor,
            .connection_options = sandbox.options,
            .session_options = session_options,
            .configuration = configuration,
            .credentials = credentials,
            .endpoints = endpoints,
            .endpoint_resolver = EndpointResolver.init(endpoints),
            .cache_dir = cache_dir,
            .status = .disconnected,
            .events = null,
            .current_session = null,
            .current_endpoint = null,
            .tunnel = null,
        };
        log.write(.notice, "Using v3 connection");
        return created.asConnection();
    }

    fn destroy(self: *OpenVPNConnection) void {
        log.write(.debug, "Deinit _OpenVPNConnectionV3");
        self.destroyCurrentSession();
        self.clearLink();
        self.endpoint_resolver.deinit(self.allocator);
        core.util.freeSlice(api.ExtendedEndpoint, self.allocator, self.endpoints);
        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.cache_dir);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn asConnection(self: *OpenVPNConnection) net.Connection {
        return .{
            .ptr = self,
            .vtable = &openvpn_connection_vtable,
        };
    }

    fn start(
        self: *OpenVPNConnection,
        events: net.Connection.Events,
    ) net.ConnectionStartError!bool {
        if (self.status != .disconnected) {
            log.writef(.err, "Ignore start, connection status {s} != .disconnected", .{
                self.status.raw(),
            });
            return false;
        }

        self.destroyCurrentSession();
        self.clearLink();

        const ca_filename = api.moduleCacheFilename(
            self.allocator,
            self.module_id,
            TLSConstants.ca_filename,
        ) catch |err| {
            log.writef(.err, "Unable to create session: {s}", .{@errorName(err)});
            return error.UnableToStart;
        };
        defer self.allocator.free(ca_filename);

        const session_events = SessionEvents{
            .context = self,
            .established = sessionEstablished,
            .failed = sessionFailed,
            .data_count = sessionDataCount,
        };
        const session = Session.create(self.allocator, .{
            .looper = self.looper,
            .events = session_events,
            .configuration = self.configuration,
            .credentials = self.credentials,
            .prng = PRNG.system(),
            .caches_directory = self.cache_dir,
            .ca_filename = ca_filename,
            .options = self.session_options,
        }) catch |err| {
            log.writef(.err, "Unable to create session: {s}", .{@errorName(err)});
            return error.UnableToStart;
        };
        self.current_session = session;
        self.events = events;

        self.clearServerConfiguration();
        _ = self.sendStatus(.connecting, events);
        const current_endpoint = self.setupLink(session) catch |err| {
            log.writef(.fault, "Unable to set up link: {s}", .{@errorName(err)});
            _ = self.sendStatus(.disconnected, events);
            session.shutdown(errors_mod.sessionError(err), null) catch {};
            self.events = null;
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnableToStart,
            };
        };
        self.current_endpoint = current_endpoint;
        return true;
    }

    fn stop(
        self: *OpenVPNConnection,
        timeout_ms: u32,
        events: net.Connection.Events,
    ) void {
        const session = self.current_session orelse return;
        if (self.status == .disconnected) {
            log.write(.err, "Ignore stop, connection not started");
            return;
        }

        _ = self.sendStatus(.disconnecting, events);
        log.write(.info, "User requested disconnection");
        var graceful = true;
        session.shutdown(null, timeout_ms) catch {
            graceful = false;
            log.write(.err, "Link shut down due to timeout");
        };
        if (graceful) log.write(.notice, "Link shut down gracefully");
        self.finalizeSession(events, .explicit_stop);
    }

    fn networkChange(
        _: *OpenVPNConnection,
        _: net.ReachabilityInfo,
        _: net.Connection.Events,
    ) void {
        // Active links report better-path or I/O failure themselves. The
        // daemon gates a new start on reachability after disconnection.
    }

    fn betterPath(
        self: *OpenVPNConnection,
        events: net.Connection.Events,
    ) void {
        const session = self.current_session orelse return;
        if (self.status == .disconnected or self.status == .disconnecting) return;
        log.write(.notice, "Link has a better path, shut down session to reconnect");
        session.shutdown(error.NetworkChanged, null) catch |err| {
            log.writef(.err, "Better-path shutdown failed: {s}", .{@errorName(err)});
        };
        self.finalizeSession(events, .{ .session_failed = error.NetworkChanged });
    }

    fn looperTerminated(
        self: *OpenVPNConnection,
        failure: ?net.Looper.Failure,
    ) void {
        const session = self.current_session orelse return;
        session.looperTerminated(failure);
    }

    // MARK: - Link setup

    fn setupLink(
        self: *OpenVPNConnection,
        session: *Session,
    ) (std.mem.Allocator.Error || error{ ExhaustedEndpoints, LinkNotActive } || Session.Error)!api.ExtendedEndpoint {
        log.write(.notice, "Create new link");
        log.write(.notice, "Cycle to next endpoint");
        const reachability = self.factory.currentReachability();
        const endpoint = try self.endpoint_resolver.next(
            self.allocator,
            &self.resolver,
            reachability,
            self.connection_options.dns_timeout,
        );

        var owned_endpoint = try endpoint.clone(self.allocator);
        errdefer owned_endpoint.deinit(self.allocator);
        log.writef(.notice, "Connect to {s}", .{owned_endpoint});
        const descriptor = try self.factory.create(
            self.allocator,
            owned_endpoint,
            reachability,
            self.connection_options.link_activity_timeout,
        );
        log.write(.notice, "Link is active");
        log.writef(.info, "Link type is {s}", .{
            owned_endpoint.proto.socket_type.raw(),
        });
        try session.setLink(descriptor, owned_endpoint);
        return owned_endpoint;
    }

    // MARK: - Session events

    fn handleSessionEstablished(
        self: *OpenVPNConnection,
        session: *Session,
        remote_endpoint: api.ExtendedEndpoint,
        remote_options: *const api.OpenVPNConfiguration,
    ) void {
        if (self.status != .connecting) return;
        log.write(.notice, "Session established");
        const address = api.Address.parseRaw(remote_endpoint.address) orelse {
            self.failTunnelSetup(session, .invalidValue);
            return;
        };
        log.writef(.info, "\tEndpoint: {s}", .{address});
        log.writef(.info, "\tProtocol: {s}:{d}", .{
            remote_endpoint.proto.socket_type.raw(),
            remote_endpoint.proto.port,
        });
        log.write(.notice, "Local options:");
        openvpn_log.logConfiguration(&self.configuration, true);
        log.write(.notice, "Remote options:");
        openvpn_log.logConfiguration(remote_options, false);
        std.debug.assert(self.events != null);
        const events = self.events orelse return;
        self.reportServerConfiguration(remote_options);

        const builder = NetworkSettingsBuilder.init(
            &self.configuration,
            remote_options,
        );
        const modules = builder.modules(self.allocator) catch |err| {
            self.failTunnelSetup(session, tunnelErrorCode(err));
            return;
        };
        defer core.util.freeSlice(api.TaggedModule, self.allocator, modules);

        const info = api.TunnelRemoteInfoWrapper{
            .profile = self.profile.*,
            .original_module_id = self.module_id,
            .address = address,
            .requires_virtual_device = true,
            .modules = modules,
        };
        self.tunnel = self.controller.setTunnelSettings(info) catch |err| {
            self.failTunnelSetup(session, tunnelErrorCode(err));
            return;
        };
        const active_tunnel = if (self.tunnel) |*value| value else {
            self.failTunnelSetup(session, .tunNotAvailable);
            return;
        };
        const fd = active_tunnel.muxDescriptor() orelse {
            self.failTunnelSetup(session, .fdUnavailable);
            return;
        };
        const descriptor = net.Looper.Descriptor{
            .fd = fd,
            .io = active_tunnel.nativeIO(),
        };
        session.setTunnel(descriptor) catch |err| {
            self.failTunnelSetup(session, tunnelErrorCode(err));
            return;
        };
        if (self.sendStatus(.connected, events)) {
            log.write(.notice, "Tunnel interface is now UP");
        }
    }

    fn failTunnelSetup(
        self: *OpenVPNConnection,
        session: *Session,
        code: api.PartoutErrorCode,
    ) void {
        log.writef(.err, "Unable to start tunnel: {s}", .{
            code.raw(),
        });
        const events = self.events orelse return;
        session.shutdown(error.Reconnect, null) catch {};
        self.finalizeSession(events, .{ .tunnel_setup_failed = code });
    }

    fn handleSessionFailure(
        self: *OpenVPNConnection,
        cause: SessionError,
    ) void {
        if (self.status == .disconnected or self.status == .disconnecting) return;
        std.debug.assert(self.current_session != null);
        const session = self.current_session orelse return;
        std.debug.assert(self.events != null);
        const events = self.events orelse return;
        session.shutdown(cause, null) catch |err| {
            log.writef(.err, "Session failure shutdown failed: {s}", .{@errorName(err)});
        };
        self.finalizeSession(events, .{ .session_failed = cause });
    }

    /// Releases connection-owned resources after the Session has stopped.
    /// Reporting stays here so every terminal path observes the same
    /// cleanup-before-callback ordering.
    fn finalizeSession(
        self: *OpenVPNConnection,
        events: net.Connection.Events,
        finalization: SessionFinalization,
    ) void {
        self.clearLink();
        self.controller.clearTunnelSettings(false);

        switch (finalization) {
            .explicit_stop => {
                _ = self.sendStatus(.disconnected, events);
                self.events = null;
            },
            .tunnel_setup_failed => |code| {
                self.markDisconnected();
                events.last_error(events.ctx, code);
                events.cancel(events.ctx, code);
            },
            .session_failed => |cause| {
                log.writef(.err, "Session failed: {s}", .{@errorName(cause)});
                if (errors_mod.partoutCode(cause)) |code| {
                    events.last_error(events.ctx, code);
                    if (!isRecoverable(cause)) {
                        log.write(.err, "Disconnection is not recoverable");
                        log.writef(.info, "Report link failure: {s}", .{@errorName(cause)});
                        self.markDisconnected();
                        events.cancel(events.ctx, code);
                        return;
                    }
                }
                // The .disconnected status will trigger a reconnection
                // in the daemon.
                _ = self.sendStatus(.disconnected, events);
                self.events = null;
            },
        }
    }

    fn markDisconnected(self: *OpenVPNConnection) void {
        self.status = .disconnected;
        self.events = null;
        self.clearServerConfiguration();
    }

    fn sendStatus(
        self: *OpenVPNConnection,
        new_status: api.ConnectionStatus,
        events: net.Connection.Events,
    ) bool {
        if (!net.canChangeStatus(self.status, new_status)) {
            log.writef(.err, "Ignore unexpected status change: {s} -> {s}", .{
                self.status.raw(),
                new_status.raw(),
            });
            return false;
        }
        log.writef(.info, "Report link status: {s}", .{new_status.raw()});
        self.status = new_status;
        events.status(events.ctx, new_status);
        if (new_status == .disconnected) self.clearServerConfiguration();
        return true;
    }

    fn reportServerConfiguration(
        self: *OpenVPNConnection,
        configuration: *const api.OpenVPNConfiguration,
    ) void {
        const value = core.util.encodeJsonValue(self.allocator, configuration) catch {
            log.write(.err, "Unable to encode server configuration");
            return;
        };
        defer self.allocator.free(value);
        self.controller.setEnvironmentValue(EnvironmentKeys.server_configuration, value);
    }

    fn clearServerConfiguration(self: *OpenVPNConnection) void {
        self.controller.setEnvironmentValue(EnvironmentKeys.server_configuration, null);
    }

    // MARK: - Cleanup

    fn destroyCurrentSession(self: *OpenVPNConnection) void {
        const session = self.current_session orelse return;
        session.destroy();
        self.current_session = null;
    }

    fn clearLink(self: *OpenVPNConnection) void {
        if (self.tunnel) |*tunnel| tunnel.deinit();
        self.tunnel = null;
        if (self.current_endpoint) |*endpoint| endpoint.deinit(self.allocator);
        self.current_endpoint = null;
    }
};

const SessionFinalization = union(enum) {
    explicit_stop,
    tunnel_setup_failed: api.PartoutErrorCode,
    session_failed: SessionError,
};

const SessionEvent = union(enum) {
    established: struct {
        session: *anyopaque,
        remote_endpoint: api.ExtendedEndpoint,
        remote_options: api.OpenVPNConfiguration,
    },
    failed: struct {
        session: *anyopaque,
        cause: SessionError,
    },
    data_count: struct {
        session: *anyopaque,
        data_count: api.DataCount,
    },

    fn session(self: SessionEvent) *anyopaque {
        return switch (self) {
            .established => |payload| payload.session,
            .failed => |payload| payload.session,
            .data_count => |payload| payload.session,
        };
    }

    fn isRequired(self: SessionEvent) bool {
        return switch (self) {
            .established, .failed => true,
            .data_count => false,
        };
    }

    fn deinit(self: *SessionEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .established => |*payload| {
                payload.remote_endpoint.deinit(allocator);
                payload.remote_options.deinit(allocator);
            },
            .failed, .data_count => {},
        }
    }
};

const SessionEventTask = struct {
    allocator: std.mem.Allocator,
    connection: *OpenVPNConnection,
    event: SessionEvent,

    fn run(raw: *anyopaque) void {
        const task: *SessionEventTask = @ptrCast(@alignCast(raw));
        defer task.deinit();
        consumeSessionEvent(task.connection, task.event);
    }

    fn discard(raw: *anyopaque) void {
        const task: *SessionEventTask = @ptrCast(@alignCast(raw));
        task.deinit();
    }

    fn deinit(task: *SessionEventTask) void {
        task.event.deinit(task.allocator);
        task.allocator.destroy(task);
    }
};

fn sendSessionEvent(self: *OpenVPNConnection, event: SessionEvent) void {
    const is_required = event.isRequired();
    const task = self.allocator.create(SessionEventTask) catch |err| {
        var owned_event = event;
        owned_event.deinit(self.allocator);
        rejectSessionEvent(err, is_required);
        return;
    };
    task.* = .{
        .allocator = self.allocator,
        .connection = self,
        .event = event,
    };
    self.serialized_executor.tryRunOwned(
        task,
        SessionEventTask.run,
        SessionEventTask.discard,
    ) catch |err| {
        SessionEventTask.discard(task);
        rejectSessionEvent(err, is_required);
    };
}

fn rejectSessionEvent(err: core.SerializedExecutor.RunError, is_required: bool) void {
    if (err == error.Closed) return;
    // Required facts have no error channel. Continuing would strand the
    // connection between states; match Swift's nonthrowing stream delivery.
    if (is_required) @panic("Unable to deliver required OpenVPN session event");
    log.writef(.err, "Unable to send session event: {s}", .{@errorName(err)});
}

fn consumeSessionEvent(self: *OpenVPNConnection, event: SessionEvent) void {
    const current = self.current_session orelse {
        log.write(.debug, "Ignore event without current session");
        return;
    };
    if (event.session() != @as(*anyopaque, @ptrCast(current))) {
        log.write(.info, "Ignoring event from old session");
        return;
    }
    switch (event) {
        .established => |payload| self.handleSessionEstablished(
            current,
            payload.remote_endpoint,
            &payload.remote_options,
        ),
        .failed => |payload| self.handleSessionFailure(payload.cause),
        .data_count => |payload| {
            if (self.status != .connected) return;
            log.writef(.debug, "Updated data count: received={d}, sent={d}", .{
                payload.data_count.received,
                payload.data_count.sent,
            });
            const events = self.events orelse return;
            events.data_count(events.ctx, payload.data_count);
        },
    }
}

// MARK: - Session event callbacks

fn sessionEstablished(
    raw: ?*anyopaque,
    session: *anyopaque,
    remote_endpoint: api.ExtendedEndpoint,
    remote_options: *const api.OpenVPNConfiguration,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(raw.?));
    const endpoint = remote_endpoint.clone(self.allocator) catch
        @panic("Unable to retain required OpenVPN session event");
    const options = remote_options.clone(self.allocator) catch {
        endpoint.deinit(self.allocator);
        @panic("Unable to retain required OpenVPN session event");
    };
    sendSessionEvent(self, .{ .established = .{
        .session = session,
        .remote_endpoint = endpoint,
        .remote_options = options,
    } });
}

fn sessionFailed(
    raw: ?*anyopaque,
    session: *anyopaque,
    cause: SessionError,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(raw.?));
    sendSessionEvent(self, .{ .failed = .{
        .session = session,
        .cause = cause,
    } });
}

fn sessionDataCount(
    raw: ?*anyopaque,
    session: *anyopaque,
    data_count: api.DataCount,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(raw.?));
    sendSessionEvent(self, .{ .data_count = .{
        .session = session,
        .data_count = data_count,
    } });
}

// MARK: - Errors

fn isRecoverable(err: SessionError) bool {
    return switch (err) {
        error.Timeout,
        error.ConnectionFailure,
        error.BadCredentialsWithLocalOptions,
        error.ServerShutdown,
        error.NetworkChanged,
        error.Reconnect,
        => true,
        else => false,
    };
}

fn tunnelErrorCode(err: anyerror) api.PartoutErrorCode {
    return switch (err) {
        error.TunNotAvailable => .tunNotAvailable,
        error.SocketConfiguration => .socketConfiguration,
        error.NetworkChanged => .networkChanged,
        error.Timeout => .timeout,
        error.CryptoFailure => .crypto,
        else => .unhandled,
    };
}

// MARK: - Connection callbacks

fn start(
    ptr: *anyopaque,
    events: net.Connection.Events,
) net.ConnectionStartError!bool {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    return self.start(events);
}

fn stop(
    ptr: *anyopaque,
    timeout_ms: u32,
    events: net.Connection.Events,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.stop(timeout_ms, events);
}

fn networkChange(
    ptr: *anyopaque,
    reachability: net.ReachabilityInfo,
    events: net.Connection.Events,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.networkChange(reachability, events);
}

fn betterPath(ptr: *anyopaque, events: net.Connection.Events) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.betterPath(events);
}

fn looperTerminated(
    ptr: *anyopaque,
    failure: ?net.Looper.Failure,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.looperTerminated(failure);
}

fn destroy(ptr: *anyopaque) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.destroy();
}

// MARK: - Vtables

const openvpn_connection_vtable = net.Connection.VTable{
    .start = start,
    .stop = stop,
    .network_change = networkChange,
    .better_path = betterPath,
    .destroy = destroy,
    .looper_terminated = looperTerminated,
};
