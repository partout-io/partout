// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const auth_mod = @import("internal/auth.zig");
const configuration_mod = @import("internal/configuration.zig");
const constants_mod = @import("internal/constants.zig");
const crypto_mod = @import("internal/crypto.zig");
const endpoint_resolver_mod = @import("internal/endpoint_resolver.zig");
const logging_mod = @import("internal/logging.zig");
const processing_mod = @import("internal/processing.zig");
const session_mod = @import("internal/session.zig");
const settings_mod = @import("internal/settings.zig");

const api = core.api;
const log = core.logging;
const openvpn_log = logging_mod;
const AuthToken = auth_mod.AuthToken;
const EndpointResolver = endpoint_resolver_mod.EndpointResolver;
const NetworkSettingsBuilder = settings_mod.NetworkSettingsBuilder;
const PRNG = crypto_mod.PRNG;
const Session = session_mod.Session;
const SessionError = session_mod.SessionError;
const SessionEvents = session_mod.SessionEvents;
const SessionOptions = configuration_mod.SessionOptions;
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
    session_options: SessionOptions,
};

const LinkSetupError = std.mem.Allocator.Error ||
    net.Looper.AttachError ||
    processing_mod.ProcessorError ||
    error{
        ExhaustedEndpoints,
        LinkFailure,
        LinkNotActive,
    };

const ConnectionError = SessionError || error{
    InvalidEndpoint,
    ModulesAllocation,
    MuxFailure,
    NetworkChanged,
    TunNotAvailable,
};

const OpenVPNConnection = struct {
    allocator: std.mem.Allocator,
    module_id: api.UUID,
    profile: *const api.Profile,
    controller: net.TunnelController,
    resolver: net.DNSResolver,
    factory: net.SocketFactory,
    looper: *net.Looper,
    serialized_executor: core.SerializedExecutor,
    connection_options: net.ConnectionOptions,
    session_options: SessionOptions,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    auth_token: AuthToken,
    endpoints: []api.ExtendedEndpoint,
    endpoint_resolver: EndpointResolver,
    cache_dir: []u8,

    status: api.ConnectionStatus,
    events: ?net.Connection.Events,
    with_local_options: bool,
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
            error.CryptoPRNG => return error.IdGeneration,
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
            .auth_token = .{},
            .endpoints = endpoints,
            .endpoint_resolver = EndpointResolver.init(endpoints),
            .cache_dir = cache_dir,
            .status = .disconnected,
            .events = null,
            .with_local_options = true,
            .current_session = null,
            .current_endpoint = null,
            .tunnel = null,
        };
        log.writef(
            .notice,
            "Using v3 connection (crypto = {s})",
            .{@tagName(session_options.backend)},
        );
        return created.asConnection();
    }

    fn destroy(self: *OpenVPNConnection) void {
        log.write(.debug, "Deinit _OpenVPNConnectionV3");
        self.destroyCurrentSession();
        self.auth_token.deinit();
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
            .auth_token = &self.auth_token,
            .prng = PRNG.system(),
            .caches_directory = self.cache_dir,
            .ca_filename = ca_filename,
            .with_local_options = self.with_local_options,
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
            session.shutdown(false, null) catch {};
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
        const session = self.current_session orelse {
            self.auth_token.clear();
            return;
        };
        if (self.status == .disconnected) {
            self.auth_token.clear();
            log.write(.err, "Ignore stop, connection not started");
            return;
        }

        _ = self.sendStatus(.disconnecting, events);
        log.write(.info, "User requested disconnection");
        var graceful = true;
        session.shutdown(true, timeout_ms) catch {
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
        session.shutdown(true, null) catch |err| {
            log.writef(.err, "Better-path shutdown failed: {s}", .{@errorName(err)});
        };
        self.finalizeSession(events, .{ .failure = .{
            .cause = error.NetworkChanged,
        } });
    }

    fn looperTerminated(
        self: *OpenVPNConnection,
        failure: ?net.Looper.Failure,
    ) void {
        const session = self.current_session orelse return;
        session.looperTerminated(failure);
    }

    // MARK: - Link setup

    fn setupLink(self: *OpenVPNConnection, session: *Session) LinkSetupError!api.ExtendedEndpoint {
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
            log.write(.fault, "Unable to parse remote endpoint");
            self.failTunnelSetup(session, error.InvalidEndpoint);
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
            log.writef(.fault, "Unable to allocate settings modules: {s}", .{@errorName(err)});
            self.failTunnelSetup(session, error.ModulesAllocation);
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
            log.writef(.fault, "Unable to establish tunnel settings: {s}", .{@errorName(err)});
            self.failTunnelSetup(session, error.TunNotAvailable);
            return;
        };
        const active_tunnel = if (self.tunnel) |*value| value else {
            log.write(.fault, "Unable to get tun device");
            self.failTunnelSetup(session, error.TunNotAvailable);
            return;
        };
        const fd = active_tunnel.muxDescriptor() orelse {
            log.write(.fault, "Unable to get mux descriptor");
            self.failTunnelSetup(session, error.MuxFailure);
            return;
        };
        const descriptor = net.Looper.Descriptor{
            .fd = fd,
            .io = active_tunnel.nativeIO(),
        };
        session.setTunnel(descriptor) catch |err| {
            log.writef(.fault, "Unable to set tunnel: {s}", .{@errorName(err)});
            self.failTunnelSetup(session, error.TunnelFailure);
            return;
        };
        if (self.sendStatus(.connected, events)) {
            log.write(.notice, "Tunnel interface is now UP");
        }
    }

    fn failTunnelSetup(
        self: *OpenVPNConnection,
        session: *Session,
        err: ConnectionError,
    ) void {
        log.writef(.err, "Unable to start tunnel: {s}", .{@errorName(err)});
        const events = self.events orelse return;
        session.shutdown(false, null) catch {};
        self.finalizeSession(events, .{ .failure = .{
            .cause = err,
        } });
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
        if (cause == error.BadCredentialsWithLocalOptions)
            self.with_local_options = false;
        session.shutdown(false, null) catch |err| {
            log.writef(.err, "Session failure shutdown failed: {s}", .{@errorName(err)});
        };
        log.writef(.err, "Session failed: {s}", .{@errorName(cause)});
        self.finalizeSession(events, .{ .failure = .{
            .cause = cause,
        } });
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
                self.auth_token.clear();
                _ = self.sendStatus(.disconnected, events);
                self.events = null;
            },
            .failure => |failure| {
                const disp = failure.disposition();
                if (disp == .cancel) {
                    log.write(.err, "Disconnection is not recoverable");
                    self.prepareTerminalCancellation();
                }
                const error_code = partoutCodeForError(failure.cause);
                events.last_error(events.ctx, error_code);
                switch (disp) {
                    .reconnect => {
                        // The .disconnected status will trigger a reconnection
                        // in the daemon.
                        _ = self.sendStatus(.disconnected, events);
                        self.events = null;
                    },
                    .cancel => events.cancel(events.ctx, error_code),
                }
            },
        }
    }

    fn prepareTerminalCancellation(self: *OpenVPNConnection) void {
        self.auth_token.clear();
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
        handleSessionEvent(task.connection, task.event);
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
        handleUndeliveredSessionEvent(err, is_required);
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
        handleUndeliveredSessionEvent(err, is_required);
    };
}

fn handleUndeliveredSessionEvent(err: core.SerializedExecutor.RunError, is_required: bool) void {
    if (err == error.Closed) return;
    // Required facts have no error channel. Continuing would strand the
    // connection between states; match Swift's nonthrowing stream delivery.
    if (is_required) @panic("Unable to deliver required OpenVPN session event");
    log.writef(.err, "Unable to send session event: {s}", .{@errorName(err)});
}

fn handleSessionEvent(self: *OpenVPNConnection, event: SessionEvent) void {
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

// MARK: - Finalization and error mapping

const SessionFinalization = union(enum) {
    explicit_stop,
    failure: SessionFinalizationFailure,
};

const SessionFinalizationFailure = struct {
    const Disposition = enum {
        reconnect,
        cancel,
    };

    cause: ConnectionError,

    fn disposition(self: *const SessionFinalizationFailure) Disposition {
        return switch (self.cause) {
            error.BadCredentials,
            error.CompressionMismatch,
            error.InvalidPushReply,
            error.NoRouting,
            error.TLSFailure,
            error.UnsupportedAlgorithm,
            error.UnsupportedCompression,
            error.UnsupportedCryptoBackend,
            => .cancel,

            error.AckIdsTooLong,
            error.Backpressure,
            error.BadCredentialsWithLocalOptions,
            error.ContinuationPushReply,
            error.ControlChannelFailure,
            error.CryptoDerivation,
            error.CryptoEncryption,
            error.CryptoHMAC,
            error.CryptoPRNG,
            error.DataPathFailure,
            error.EndOfStream,
            error.InvalidAck,
            error.InvalidEndpoint,
            error.InvalidKey,
            error.InvalidPacketId,
            error.InvalidSessionId,
            error.LibcFailure,
            error.LinkFailure,
            error.LooperTerminated,
            error.LooperUnavailable,
            error.MissingSessionId,
            error.ModulesAllocation,
            error.MuxFailure,
            error.NetworkChanged,
            error.OOBOutsideQueue,
            error.OutOfBounds,
            error.OutOfMemory,
            error.Overflow,
            error.PacketTooLarge,
            error.PeerIdMismatch,
            error.ServerShutdown,
            error.SessionMismatch,
            error.SessionStale,
            error.Timeout,
            error.TransformFailure,
            error.TunnelFailure,
            error.TunNotAvailable,
            error.WouldBlock,
            error.WriteIncomplete,
            error.WrongControlDataPrefix,
            => .reconnect,
        };
    }
};

pub const testing = struct {
    pub fn isRecoverableError(cause: ConnectionError) bool {
        return (SessionFinalizationFailure{ .cause = cause }).disposition() == .reconnect;
    }

    pub const codeForError = partoutCodeForError;
};

fn partoutCodeForError(err: ConnectionError) api.PartoutErrorCode {
    return switch (err) {
        error.BadCredentials => .authentication,
        error.BadCredentialsWithLocalOptions => .openVPNRecoverableAuthentication,
        error.CompressionMismatch => .openVPNCompressionMismatch,
        error.CryptoEncryption,
        error.CryptoHMAC,
        error.CryptoPRNG,
        => .crypto,
        error.InvalidEndpoint => .invalidValue,
        error.ModulesAllocation => .unhandled,
        error.MuxFailure => .fdUnavailable,
        error.NetworkChanged => .networkChanged,
        error.NoRouting => .openVPNNoRouting,
        error.ServerShutdown => .openVPNServerShutdown,
        error.TLSFailure => .openVPNTLSFailure,
        error.Timeout => .timeout,
        error.TunNotAvailable => .tunNotAvailable,
        error.CryptoDerivation,
        error.UnsupportedAlgorithm,
        error.UnsupportedCryptoBackend,
        => .openVPNUnsupportedAlgorithm,
        error.UnsupportedCompression => .openVPNUnsupportedCompression,

        error.AckIdsTooLong,
        error.Backpressure,
        error.ContinuationPushReply,
        error.ControlChannelFailure,
        error.DataPathFailure,
        error.EndOfStream,
        error.InvalidAck,
        error.InvalidKey,
        error.InvalidPacketId,
        error.InvalidPushReply,
        error.InvalidSessionId,
        error.LibcFailure,
        error.LinkFailure,
        error.LooperTerminated,
        error.LooperUnavailable,
        error.MissingSessionId,
        error.OOBOutsideQueue,
        error.OutOfBounds,
        error.OutOfMemory,
        error.Overflow,
        error.PacketTooLarge,
        error.PeerIdMismatch,
        error.SessionMismatch,
        error.SessionStale,
        error.TransformFailure,
        error.TunnelFailure,
        error.WouldBlock,
        error.WriteIncomplete,
        error.WrongControlDataPrefix,
        => .openVPNConnectionFailure,
    };
}
