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
const SessionDelegate = session_mod.SessionDelegate;
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

    delegate_events: DelegateEventQueue,

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
            .delegate_events = DelegateEventQueue.init(),
        };
        log.write(.notice, "Using v3 connection");
        return created.asConnection();
    }

    fn destroy(self: *OpenVPNConnection) void {
        log.write(.debug, "Deinit _OpenVPNConnectionV3");
        self.destroyCurrentSession();
        self.clearLink();
        self.delegate_events.deinit(self.allocator);
        self.endpoint_resolver.deinit(self.allocator);
        core.util.freeSlice(api.ExtendedEndpoint, self.allocator, self.endpoints);
        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.cache_dir);
        const allocator = self.allocator;
        allocator.destroy(self);
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
        const session = Session.create(self.allocator, .{
            .lifecycle_executor = self.serialized_executor,
            .looper = self.looper,
            .delegate = self.sessionDelegate(),
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
            session.setDelegate(null);
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
        // The generic Connection contract forbids callbacks after stop().
        // Removing the delegate also lets shutdown complete synchronously
        // without queueing a didStop event behind the daemon's stop message.
        session.setDelegate(null);
        var graceful = true;
        session.shutdown(null, timeout_ms) catch {
            graceful = false;
            log.write(.err, "Link shut down due to timeout");
        };
        if (graceful) log.write(.notice, "Link shut down gracefully");
        self.delegate_events.clear(self.allocator);
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
        _: net.Connection.Events,
    ) void {
        const session = self.current_session orelse return;
        if (self.status == .disconnected or self.status == .disconnecting) return;
        log.write(.notice, "Link has a better path, shut down session to reconnect");
        session.shutdown(error.NetworkChanged, null) catch |err| {
            log.writef(.err, "Better-path shutdown failed: {s}", .{@errorName(err)});
        };
    }

    fn looperDidTerminate(
        self: *OpenVPNConnection,
        failure: ?net.Looper.Failure,
    ) void {
        const session = self.current_session orelse return;
        session.looperDidTerminate(failure);
    }

    // MARK: - Private construction

    fn asConnection(self: *OpenVPNConnection) net.Connection {
        return .{
            .ptr = self,
            .vtable = &openvpn_connection_vtable,
        };
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

    // MARK: - Session delegate

    fn sessionDelegate(self: *OpenVPNConnection) SessionDelegate {
        return .{
            .context = self,
            .vtable = &session_delegate_vtable,
        };
    }

    fn enqueueDelegateEvent(self: *OpenVPNConnection, event: DelegateEvent) void {
        self.delegate_events.append(self.allocator, event) catch {
            var owned_event = event;
            owned_event.deinit(self.allocator);
            log.write(.err, "Unable to enqueue session delegate event");
            return;
        };
        self.serialized_executor.run(self, handleDelegateEventsTask);
    }

    fn handleDelegateEventsTask(raw: *anyopaque) void {
        const self: *OpenVPNConnection = @ptrCast(@alignCast(raw));
        self.handleDelegateEvents();
    }

    fn handleDelegateEvents(self: *OpenVPNConnection) void {
        while (self.delegate_events.take(self.allocator)) |queued_event| {
            var event = queued_event;
            self.handleDelegateEvent(event);
            event.deinit(self.allocator);
        }
    }

    fn handleDelegateEvent(
        self: *OpenVPNConnection,
        event: DelegateEvent,
    ) void {
        const current = self.current_session orelse {
            log.write(.debug, "Ignore event without current session");
            return;
        };
        if (event.session() != @as(*anyopaque, @ptrCast(current))) {
            log.write(.info, "Ignoring delegate event from old session");
            return;
        }
        switch (event) {
            .did_start => |payload| self.handleDidStart(
                current,
                payload.remote_endpoint,
                &payload.remote_options,
            ),
            .did_stop => |payload| self.handleDidStop(payload.cause),
            .did_update_data_count => |payload| {
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

    fn handleDidStart(
        self: *OpenVPNConnection,
        session: *Session,
        remote_endpoint: api.ExtendedEndpoint,
        remote_options: *const api.OpenVPNConfiguration,
    ) void {
        log.write(.notice, "Session did start");
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
        session.setDelegate(null);
        session.shutdown(error.Reconnect, null) catch {};
        self.finalizeSession(events, .{ .tunnel_setup_failed = code });
    }

    fn handleDidStop(
        self: *OpenVPNConnection,
        cause: ?SessionError,
    ) void {
        const events = self.events orelse return;
        self.finalizeSession(events, .{ .session_stopped = cause });
    }

    /// Releases connection-owned resources after the Session has stopped or
    /// had its delegate removed. Reporting stays here so every terminal path
    /// observes the same cleanup-before-callback ordering.
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
            .session_stopped => |cause| {
                if (self.status == .disconnecting) return;
                if (cause) |err| {
                    log.writef(.err, "Session did stop: {s}", .{@errorName(err)});
                    if (errors_mod.partoutCode(err)) |code| {
                        events.last_error(events.ctx, code);
                        if (!isRecoverable(err)) {
                            log.write(.err, "Disconnection is not recoverable");
                            log.writef(.info, "Report link failure: {s}", .{@errorName(err)});
                            self.markDisconnected();
                            events.cancel(events.ctx, code);
                            return;
                        }
                    }
                } else {
                    log.write(.notice, "Session did stop");
                }
                _ = self.sendStatus(.disconnected, events);
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
        session.setDelegate(null);
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
    session_stopped: ?SessionError,
};

const DelegateEvent = union(enum) {
    did_start: struct {
        session: *anyopaque,
        remote_endpoint: api.ExtendedEndpoint,
        remote_options: api.OpenVPNConfiguration,
    },
    did_stop: struct {
        session: *anyopaque,
        cause: ?SessionError,
    },
    did_update_data_count: struct {
        session: *anyopaque,
        data_count: api.DataCount,
    },

    fn session(self: DelegateEvent) *anyopaque {
        return switch (self) {
            .did_start => |payload| payload.session,
            .did_stop => |payload| payload.session,
            .did_update_data_count => |payload| payload.session,
        };
    }

    fn deinit(self: *DelegateEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .did_start => |*payload| {
                payload.remote_endpoint.deinit(allocator);
                payload.remote_options.deinit(allocator);
            },
            .did_stop, .did_update_data_count => {},
        }
    }
};

const DelegateEventNode = struct {
    event: DelegateEvent,
    next: ?*DelegateEventNode,
};

const DelegateEventQueue = struct {
    lock: core.Mutex,
    head: ?*DelegateEventNode,
    tail: ?*DelegateEventNode,

    fn init() DelegateEventQueue {
        return .{
            .lock = .{},
            .head = null,
            .tail = null,
        };
    }

    fn append(
        self: *DelegateEventQueue,
        allocator: std.mem.Allocator,
        event: DelegateEvent,
    ) std.mem.Allocator.Error!void {
        const node = try allocator.create(DelegateEventNode);
        node.* = .{
            .event = event,
            .next = null,
        };

        self.lock.lock();
        defer self.lock.unlock();
        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
    }

    fn take(
        self: *DelegateEventQueue,
        allocator: std.mem.Allocator,
    ) ?DelegateEvent {
        self.lock.lock();
        const node = self.head orelse {
            self.lock.unlock();
            return null;
        };
        self.head = node.next;
        if (self.head == null) self.tail = null;
        self.lock.unlock();

        defer allocator.destroy(node);
        return node.event;
    }

    fn clear(
        self: *DelegateEventQueue,
        allocator: std.mem.Allocator,
    ) void {
        while (self.take(allocator)) |queued_event| {
            var event = queued_event;
            event.deinit(allocator);
        }
    }

    fn deinit(
        self: *DelegateEventQueue,
        allocator: std.mem.Allocator,
    ) void {
        self.clear(allocator);
        self.lock.deinit();
    }
};

// MARK: - Session delegate callbacks

fn sessionDidStart(
    raw: ?*anyopaque,
    session: *anyopaque,
    remote_endpoint: api.ExtendedEndpoint,
    remote_options: *const api.OpenVPNConfiguration,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(raw.?));
    const endpoint = remote_endpoint.clone(self.allocator) catch {
        log.write(.err, "Unable to copy started endpoint");
        return;
    };
    const options = remote_options.clone(self.allocator) catch {
        endpoint.deinit(self.allocator);
        log.write(.err, "Unable to copy pushed options");
        return;
    };
    self.enqueueDelegateEvent(.{ .did_start = .{
        .session = session,
        .remote_endpoint = endpoint,
        .remote_options = options,
    } });
}

fn sessionDidStop(
    raw: ?*anyopaque,
    session: *anyopaque,
    cause: ?SessionError,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(raw.?));
    self.enqueueDelegateEvent(.{ .did_stop = .{
        .session = session,
        .cause = cause,
    } });
}

fn sessionDidUpdateDataCount(
    raw: ?*anyopaque,
    session: *anyopaque,
    data_count: api.DataCount,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(raw.?));
    self.enqueueDelegateEvent(.{ .did_update_data_count = .{
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

fn looperDidTerminate(
    ptr: *anyopaque,
    failure: ?net.Looper.Failure,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.looperDidTerminate(failure);
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
    .looper_terminated = looperDidTerminate,
};

const session_delegate_vtable = SessionDelegate.VTable{
    .did_start = sessionDidStart,
    .did_stop = sessionDidStop,
    .did_update_data_count = sessionDidUpdateDataCount,
};
