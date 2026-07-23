// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const c_exports = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const configuration_mod = @import("internal/configuration.zig");
const crypto_mod = @import("internal/crypto.zig");
const errors_mod = @import("internal/errors.zig");
const logging_mod = @import("internal/logging.zig");
const session_mod = @import("internal/session.zig");
const settings_mod = @import("internal/settings.zig");

const api = core.api;
const c_crypto = c_exports.crypto;
const log = core.logging;
const openvpn_log = logging_mod;
const ConnectionOptions = configuration_mod.ConnectionOptions;
const NetworkSettingsBuilder = settings_mod.NetworkSettingsBuilder;
const PRNG = crypto_mod.PRNG;
const Session = session_mod.Session;
const SessionDelegate = session_mod.SessionDelegate;
const SessionError = errors_mod.SessionError;

pub const has_default_crypto_backend = builtin.is_test or
    @hasDecl(c_crypto, "PARTOUT_CRYPTO_OPENSSL") or
    @hasDecl(c_crypto, "PARTOUT_CRYPTO_MBEDTLS");

pub fn createConnection(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: net.ConnectionModule,
    sandbox: net.Sandbox,
) net.ConnectionCreateError!net.Connection {
    const raw = ptr orelse return error.MissingConnectionImplementation;
    const context: *const ConnectionContext = @ptrCast(@alignCast(raw));
    return OpenVPNConnection.create(
        allocator,
        context,
        module,
        sandbox,
    );
}

/// Inputs selected by the OpenVPN module implementation. A null function
/// table uses the platform-native crypto backend.
pub const ConnectionContext = struct {
    function_table: ?c_crypto.pp_crypto_fnt = null,
    session_options: ConnectionOptions = .{},

    pub fn init(function_table: c_crypto.pp_crypto_fnt) ConnectionContext {
        return .{ .function_table = function_table };
    }

    fn functionTable(self: *const ConnectionContext) c_crypto.pp_crypto_fnt {
        return self.function_table orelse defaultFunctionTable();
    }
};

fn defaultFunctionTable() c_crypto.pp_crypto_fnt {
    if (builtin.is_test) return c_crypto.pp_crypto_fnt_mock();
    if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_OPENSSL"))
        return c_crypto.pp_crypto_fnt_openssl();
    if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_MBEDTLS"))
        return c_crypto.pp_crypto_fnt_native();
    unreachable;
}

const OpenVPNConnection = struct {
    allocator: std.mem.Allocator,
    module_id: api.UUID,
    profile: *const api.Profile,
    controller: net.TunnelController,
    resolver: net.DNSResolver,
    factory: net.SocketFactory,
    looper: *net.Looper,
    serialized_executor: net.SerializedExecutor,
    function_table: c_crypto.pp_crypto_fnt,
    session_options: ConnectionOptions,
    connection_options: net.ConnectionOptions,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    endpoints: []api.ExtendedEndpoint,
    endpoint_resolver: EndpointResolver,
    cache_dir: []u8,

    status: api.ConnectionStatus = .disconnected,
    events: ?net.Connection.Events = null,
    current_session: ?*Session = null,
    current_endpoint: ?api.ExtendedEndpoint = null,
    tunnel: ?net.TunWrapper = null,

    event_lock: core.Mutex = .{},
    event_head: ?*DelegateEventNode = null,
    event_tail: ?*DelegateEventNode = null,

    fn create(
        allocator: std.mem.Allocator,
        context: *const ConnectionContext,
        module: net.ConnectionModule,
        sandbox: net.Sandbox,
    ) net.ConnectionCreateError!net.Connection {
        const openvpn = switch (module.module.*) {
            .OpenVPN => |*value| value,
            else => unreachable,
        };
        const source_configuration = if (openvpn.configuration) |*value|
            value
        else
            return error.IncompleteModule;
        const looper = sandbox.looper orelse
            return error.MissingConnectionImplementation;

        var configuration = configurationApplyingActiveModules(
            allocator,
            source_configuration,
            sandbox.profile,
        ) catch return error.OutOfMemory;
        errdefer configuration.deinit(allocator);

        const prng = PRNG.system();
        const maybe_endpoints = configuration_mod.processedRemotes(
            allocator,
            &configuration,
            prng,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CryptoFailure => return error.IdGeneration,
        };
        const endpoints = maybe_endpoints orelse return error.IncompleteModule;
        errdefer deinitEndpoints(allocator, endpoints);
        if (endpoints.len == 0) return error.IncompleteModule;

        var credentials = if (openvpn.credentials) |value|
            value.clone(allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidJson,
                error.InvalidModel,
                error.UnsupportedModel,
                => unreachable,
            }
        else
            null;
        errdefer if (credentials) |*value| value.deinit(allocator);

        const cache_dir = try allocator.dupe(u8, sandbox.cache_dir);
        errdefer allocator.free(cache_dir);

        const created = try allocator.create(OpenVPNConnection);
        errdefer allocator.destroy(created);
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
            .looper = looper,
            .serialized_executor = sandbox.serialized_executor,
            .function_table = context.functionTable(),
            .session_options = session_options,
            .connection_options = sandbox.options,
            .configuration = configuration,
            .credentials = credentials,
            .endpoints = endpoints,
            .endpoint_resolver = EndpointResolver.init(endpoints),
            .cache_dir = cache_dir,
        };
        log.write(.notice, "OpenVPN: Using v3 connection");
        return created.asConnection();
    }

    fn deinit(self: *OpenVPNConnection) void {
        log.write(.debug, "Deinit _OpenVPNConnectionV3");
        if (self.current_session) |session| {
            session.setDelegate(null);
            session.destroy();
            self.current_session = null;
        }
        self.clearTunnel();
        self.clearCurrentEndpoint();
        self.deinitQueuedEvents();
        self.event_lock.deinit();
        self.endpoint_resolver.deinit(self.allocator);
        deinitEndpoints(self.allocator, self.endpoints);
        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.cache_dir);
        const allocator = self.allocator;
        self.* = undefined;
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

        if (self.current_session) |old_session| {
            old_session.setDelegate(null);
            old_session.destroy();
            self.current_session = null;
        }
        self.clearTunnel();
        self.clearCurrentEndpoint();

        const session = Session.create(
            self.allocator,
            self.looper,
            self.function_table,
            self.configuration,
            self.credentials,
            PRNG.system(),
            self.cache_dir,
            self.session_options,
        ) catch |err| {
            log.writef(.err, "OpenVPN: Unable to create session: {s}", .{@errorName(err)});
            return error.UnableToStart;
        };
        session.setDelegate(self.sessionDelegate());
        self.current_session = session;
        self.events = events;

        _ = self.sendStatus(.connecting, events);
        const descriptor = self.setupLink() catch |err| {
            log.writef(.fault, "Unable to create link: {s}", .{@errorName(err)});
            _ = self.sendStatus(.disconnected, events);
            session.setDelegate(null);
            session.shutdown(errors_mod.sessionError(err), null) catch {};
            self.events = null;
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnableToStart,
            };
        };
        session.setLink(descriptor, self.current_endpoint.?) catch |err| {
            log.writef(.err, "OpenVPN: Unable to attach link: {s}", .{@errorName(err)});
            _ = self.sendStatus(.disconnected, events);
            session.setDelegate(null);
            session.shutdown(err, null) catch {};
            self.clearCurrentEndpoint();
            self.events = null;
            return error.UnableToStart;
        };
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
        self.discardQueuedEvents();
        self.clearTunnel();
        self.clearCurrentEndpoint();
        self.controller.clearTunnelSettings(false);
        _ = self.sendStatus(.disconnected, events);
        self.events = null;
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
            log.writef(.err, "OpenVPN: Better-path shutdown failed: {s}", .{@errorName(err)});
        };
    }

    fn looperDidFinish(
        self: *OpenVPNConnection,
        failure: ?net.Looper.Failure,
    ) void {
        const session = self.current_session orelse return;
        session.looperDidFinish(failure);
    }

    fn setupLink(
        self: *OpenVPNConnection,
    ) (std.mem.Allocator.Error || error{ ExhaustedEndpoints, LinkNotActive })!net.Looper.Descriptor {
        log.write(.notice, "Create new link");
        log.write(.notice, "Cycle to next endpoint");
        const reachability = self.factory.currentReachability();
        const endpoint = try self.endpoint_resolver.next(
            self.allocator,
            &self.resolver,
            reachability,
            self.sessionDnsTimeout(),
        );

        var owned_endpoint = try cloneEndpoint(self.allocator, endpoint);
        errdefer owned_endpoint.deinit(self.allocator);
        logSensitiveEndpoint(.notice, "Connect to ", owned_endpoint);
        const descriptor = self.factory.create(
            self.allocator,
            owned_endpoint,
            reachability,
            self.sessionLinkTimeout(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LinkNotActive => return error.LinkNotActive,
        };
        self.current_endpoint = owned_endpoint;
        log.write(.notice, "Link is active");
        log.writef(.info, "Link type is {s}", .{
            self.current_endpoint.?.proto.socket_type.raw(),
        });
        return descriptor;
    }

    fn sessionDnsTimeout(self: *const OpenVPNConnection) u32 {
        return self.connection_options.dns_timeout;
    }

    fn sessionLinkTimeout(self: *const OpenVPNConnection) u32 {
        return self.connection_options.link_activity_timeout;
    }

    fn sessionDelegate(self: *OpenVPNConnection) SessionDelegate {
        return .{
            .context = self,
            .vtable = &session_delegate_vtable,
        };
    }

    fn enqueueDelegateEvent(self: *OpenVPNConnection, event: DelegateEvent) void {
        const node = self.allocator.create(DelegateEventNode) catch {
            var owned_event = event;
            owned_event.deinit(self.allocator);
            log.write(.err, "OpenVPN: Unable to enqueue session delegate event");
            return;
        };
        node.* = .{ .event = event };

        self.event_lock.lock();
        if (self.event_tail) |tail| {
            tail.next = node;
        } else {
            self.event_head = node;
        }
        self.event_tail = node;
        self.event_lock.unlock();
        self.serialized_executor.run(self, handleDelegateEventsTask);
    }

    fn handleDelegateEventsTask(raw: *anyopaque) void {
        const self: *OpenVPNConnection = @ptrCast(@alignCast(raw));
        self.handleDelegateEvents();
    }

    fn handleDelegateEvents(self: *OpenVPNConnection) void {
        while (self.takeDelegateEvent()) |node| {
            self.handleDelegateEvent(node.event);
            var event = node.event;
            event.deinit(self.allocator);
            self.allocator.destroy(node);
        }
    }

    fn takeDelegateEvent(self: *OpenVPNConnection) ?*DelegateEventNode {
        self.event_lock.lock();
        defer self.event_lock.unlock();
        const node = self.event_head orelse return null;
        self.event_head = node.next;
        if (self.event_head == null) self.event_tail = null;
        node.next = null;
        return node;
    }

    fn handleDelegateEvent(
        self: *OpenVPNConnection,
        event: DelegateEvent,
    ) void {
        const current = self.current_session orelse {
            log.write(.debug, "OpenVPN: Ignore event without current session");
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
        openvpn_log.sensitiveString(.info, "\tEndpoint: ", remote_endpoint.address);
        log.writef(.info, "\tProtocol: {s}:{d}", .{
            remote_endpoint.proto.socket_type.raw(),
            remote_endpoint.proto.port,
        });
        log.write(.notice, "Local options:");
        logConfiguration(&self.configuration, true);
        log.write(.notice, "Remote options:");
        logConfiguration(remote_options, false);
        const events = self.events orelse return;

        const builder = NetworkSettingsBuilder.init(
            &self.configuration,
            remote_options,
        );
        const modules = builder.modules(self.allocator) catch |err| {
            self.failTunnelSetup(session, tunnelErrorCode(err));
            return;
        };
        defer NetworkSettingsBuilder.deinitModules(self.allocator, modules);

        const address = api.Address.parseRaw(remote_endpoint.address) orelse {
            self.failTunnelSetup(session, .invalidValue);
            return;
        };
        const info = api.TunnelRemoteInfoWrapper{
            .profile = self.profile.*,
            .original_module_id = self.module_id,
            .address = address,
            .requires_virtual_device = true,
            .modules = modules,
        };
        const tunnel = self.controller.setTunnelSettings(info) catch |err| {
            self.failTunnelSetup(session, tunnelErrorCode(err));
            return;
        };
        self.tunnel = tunnel orelse {
            self.failTunnelSetup(session, .tunNotAvailable);
            return;
        };
        const descriptor = if (self.tunnel) |*active_tunnel| blk: {
            const fd = active_tunnel.muxDescriptor() orelse {
                self.failTunnelSetup(session, .fdUnavailable);
                return;
            };
            break :blk net.Looper.Descriptor{
                .fd = fd,
                .io = active_tunnel.nativeIO(),
            };
        } else unreachable;
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
        self.clearTunnel();
        self.clearCurrentEndpoint();
        self.controller.clearTunnelSettings(false);
        self.status = .disconnected;
        self.events = null;
        events.last_error(events.ctx, code);
        self.controller.setReasserting(false);
        self.controller.cancelTunnelConnection(code);
    }

    fn handleDidStop(
        self: *OpenVPNConnection,
        cause: ?SessionError,
    ) void {
        const events = self.events orelse return;
        self.clearTunnel();
        self.clearCurrentEndpoint();
        self.controller.clearTunnelSettings(false);

        if (self.status == .disconnecting) return;
        if (cause) |err| {
            log.writef(.err, "Session did stop: {s}", .{@errorName(err)});
            if (errors_mod.partoutCode(err)) |code| {
                events.last_error(events.ctx, code);
                if (!isRecoverable(err)) {
                    log.write(.err, "Disconnection is not recoverable");
                    log.writef(.info, "Report link failure: {s}", .{@errorName(err)});
                    self.status = .disconnected;
                    self.events = null;
                    self.controller.setReasserting(false);
                    self.controller.cancelTunnelConnection(code);
                    return;
                }
            }
        } else {
            log.write(.notice, "Session did stop");
        }
        _ = self.sendStatus(.disconnected, events);
    }

    fn sendStatus(
        self: *OpenVPNConnection,
        new_status: api.ConnectionStatus,
        events: net.Connection.Events,
    ) bool {
        if (!canChangeStatus(self.status, new_status)) {
            log.writef(.err, "Ignore unexpected status change: {s} -> {s}", .{
                self.status.raw(),
                new_status.raw(),
            });
            return false;
        }
        log.writef(.info, "Report link status: {s}", .{new_status.raw()});
        self.status = new_status;
        events.status(events.ctx, new_status);
        return true;
    }

    fn clearTunnel(self: *OpenVPNConnection) void {
        if (self.tunnel) |*tunnel| tunnel.deinit();
        self.tunnel = null;
    }

    fn clearCurrentEndpoint(self: *OpenVPNConnection) void {
        if (self.current_endpoint) |*endpoint| endpoint.deinit(self.allocator);
        self.current_endpoint = null;
    }

    fn discardQueuedEvents(self: *OpenVPNConnection) void {
        while (self.takeDelegateEvent()) |node| {
            var event = node.event;
            event.deinit(self.allocator);
            self.allocator.destroy(node);
        }
    }

    fn deinitQueuedEvents(self: *OpenVPNConnection) void {
        self.discardQueuedEvents();
    }
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
    next: ?*DelegateEventNode = null,
};

fn sessionDidStart(
    raw: ?*anyopaque,
    session: *anyopaque,
    remote_endpoint: api.ExtendedEndpoint,
    remote_options: api.OpenVPNConfiguration,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(raw.?));
    const endpoint = cloneEndpoint(self.allocator, remote_endpoint) catch {
        log.write(.err, "OpenVPN: Unable to copy started endpoint");
        return;
    };
    const options = remote_options.clone(self.allocator) catch {
        endpoint.deinit(self.allocator);
        log.write(.err, "OpenVPN: Unable to copy pushed options");
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

const session_delegate_vtable = SessionDelegate.VTable{
    .did_start = sessionDidStart,
    .did_stop = sessionDidStop,
    .did_update_data_count = sessionDidUpdateDataCount,
};

fn logConfiguration(
    configuration: *const api.OpenVPNConfiguration,
    is_local: bool,
) void {
    if (is_local) {
        if (configuration.remotes) |remotes| {
            if (log.logsPrivateData()) {
                log.writef(.notice, "\tRemotes: {any}", .{remotes});
            } else {
                log.writef(.notice, "\tRemotes: [<redacted> x {d}]", .{remotes.len});
            }
        }
    } else {
        logSensitiveValue("\tIPv4: ", configuration.ipv4);
        logSensitiveValue("\tIPv6: ", configuration.ipv6);
    }
    if (configuration.routes4) |routes|
        log.writef(.notice, "\tRoutes (IPv4): {any}", .{routes});
    if (configuration.routes6) |routes|
        log.writef(.notice, "\tRoutes (IPv6): {any}", .{routes});

    if (configuration.cipher) |cipher| {
        log.writef(.notice, "\tCipher: {s}", .{cipher.raw()});
    } else if (is_local) {
        log.writef(.notice, "\tCipher: {s}", .{
            configuration_mod.fallbackCipher(configuration).raw(),
        });
    }
    if (configuration.digest) |digest| {
        log.writef(.notice, "\tDigest: {s}", .{digest.raw()});
    } else if (is_local) {
        log.writef(.notice, "\tDigest: {s}", .{
            configuration_mod.fallbackDigest(configuration).raw(),
        });
    }
    if (configuration.compression_framing) |framing| {
        log.writef(.notice, "\tCompression framing: {s}", .{@tagName(framing)});
    } else if (is_local) {
        log.writef(.notice, "\tCompression framing: {s}", .{
            @tagName(configuration_mod.fallbackCompressionFraming(configuration)),
        });
    }
    if (configuration.compression_algorithm) |algorithm| {
        log.writef(.notice, "\tCompression algorithm: {s}", .{@tagName(algorithm)});
    } else if (is_local) {
        log.writef(.notice, "\tCompression algorithm: {s}", .{
            @tagName(configuration_mod.fallbackCompressionAlgorithm(configuration)),
        });
    }

    if (is_local) {
        log.writef(.notice, "\tUsername authentication: {}", .{
            configuration.auth_user_pass orelse false,
        });
        log.writef(.notice, "\tStatic challenge: {}", .{
            configuration.static_challenge orelse false,
        });
        log.write(
            .notice,
            if (configuration.client_certificate != null)
                "\tClient verification: enabled"
            else
                "\tClient verification: disabled",
        );
        if (configuration.tls_wrap) |wrap| {
            log.writef(.notice, "\tTLS wrapping: {s}", .{wrap.strategy.raw()});
        } else {
            log.write(.notice, "\tTLS wrapping: disabled");
        }
        if (configuration.tls_security_level) |level| {
            log.writef(.notice, "\tTLS security level: {d}", .{level});
        } else {
            log.write(.notice, "\tTLS security level: default");
        }
    }

    logPositiveSeconds(
        "\tKeep-alive interval: ",
        configuration.keep_alive_interval,
        is_local,
    );
    logPositiveSeconds(
        "\tKeep-alive timeout: ",
        configuration.keep_alive_timeout,
        is_local,
    );
    logPositiveSeconds(
        "\tRenegotiation: ",
        configuration.renegotiates_after,
        is_local,
    );
    if (configuration.checks_eku orelse false) {
        log.write(.notice, "\tServer EKU verification: enabled");
    } else if (is_local) {
        log.write(.notice, "\tServer EKU verification: disabled");
    }
    if (configuration.checks_san_host orelse false) {
        if (configuration.san_host) |host| {
            if (log.logsPrivateData()) {
                log.writef(.notice, "\tHost SAN verification: enabled ({s})", .{host});
            } else {
                log.write(.notice, "\tHost SAN verification: enabled (<redacted>)");
            }
        } else {
            log.write(.notice, "\tHost SAN verification: enabled (-)");
        }
    } else if (is_local) {
        log.write(.notice, "\tHost SAN verification: disabled");
    }

    if (configuration.randomize_endpoint orelse false)
        log.write(.notice, "\tRandomize endpoint: true");
    if (configuration.randomize_hostnames orelse false)
        log.write(.notice, "\tRandomize hostnames: true");

    if (configuration.routing_policies) |policies| {
        log.writef(.notice, "\tGateway: {any}", .{policies});
    } else if (is_local) {
        log.write(.notice, "\tGateway: not configured");
    }

    if (configuration.dns_servers) |servers| {
        if (servers.len > 0) {
            logSensitiveStrings(.notice, "\tDNS: ", servers);
        } else if (is_local) {
            log.write(.notice, "\tDNS: not configured");
        }
    } else if (is_local) {
        log.write(.notice, "\tDNS: not configured");
    }
    if (configuration.dns_domain) |domain|
        openvpn_log.sensitiveString(.notice, "\tDNS domain: ", domain);
    if (configuration.search_domains) |domains| {
        if (domains.len > 0)
            logSensitiveStrings(.notice, "\tSearch domains: ", domains);
    }

    if (configuration.http_proxy) |proxy|
        logSensitiveProxy(.notice, "\tHTTP proxy: ", proxy);
    if (configuration.https_proxy) |proxy|
        logSensitiveProxy(.notice, "\tHTTPS proxy: ", proxy);
    if (configuration.proxy_auto_configuration_url) |url|
        openvpn_log.sensitiveString(.notice, "\tPAC: ", url);
    if (configuration.proxy_bypass_domains) |domains| {
        if (domains.len > 0)
            logSensitiveStrings(.notice, "\tProxy bypass domains: ", domains);
    }

    if (configuration.mtu) |mtu| {
        log.writef(.notice, "\tMTU: {d}", .{mtu});
    } else if (is_local) {
        log.write(.notice, "\tMTU: default");
    }
    if (configuration.xor_method) |method|
        log.writef(.notice, "\tXOR: {s}", .{@tagName(std.meta.activeTag(method))});
    if (configuration.no_pull_mask) |mask|
        log.writef(.notice, "\tNot pulled: {any}", .{mask});
}

fn logPositiveSeconds(
    comptime prefix: []const u8,
    value: ?f64,
    print_never: bool,
) void {
    if (value) |seconds| {
        if (seconds > 0) {
            openvpn_log.timeSeconds(.notice, prefix, seconds);
            return;
        }
    }
    if (print_never) log.write(.notice, prefix ++ "never");
}

fn logSensitiveValue(comptime prefix: []const u8, value: anytype) void {
    if (value) |unwrapped| {
        if (log.logsPrivateData()) {
            log.writef(.notice, prefix ++ "{any}", .{unwrapped});
        } else {
            log.write(.notice, prefix ++ "<redacted>");
        }
    } else {
        log.write(.notice, prefix ++ "not configured");
    }
}

fn logSensitiveStrings(
    level: core.logging.Level,
    comptime prefix: []const u8,
    values: []const []const u8,
) void {
    if (log.logsPrivateData()) {
        log.writef(level, prefix ++ "{any}", .{values});
    } else {
        log.writef(level, prefix ++ "[<redacted> x {d}]", .{values.len});
    }
}

fn logSensitiveProxy(
    level: core.logging.Level,
    comptime prefix: []const u8,
    endpoint: api.Endpoint,
) void {
    if (log.logsPrivateData()) {
        log.writef(level, prefix ++ "{s}:{d}", .{ endpoint.address, endpoint.port });
    } else {
        log.write(level, prefix ++ "<redacted>");
    }
}

fn logSensitiveEndpoint(
    level: core.logging.Level,
    comptime prefix: []const u8,
    endpoint: api.ExtendedEndpoint,
) void {
    if (log.logsPrivateData()) {
        log.writef(level, prefix ++ "{s}:{s}:{d}", .{
            endpoint.address,
            endpoint.proto.socket_type.raw(),
            endpoint.proto.port,
        });
    } else {
        log.write(level, prefix ++ "<redacted>");
    }
}

const EndpointResolver = struct {
    endpoints: []const api.ExtendedEndpoint,
    next_endpoint_index: usize = 0,
    resolved: ?[]api.ExtendedEndpoint = null,
    next_resolved_index: usize = 0,

    fn init(endpoints: []const api.ExtendedEndpoint) EndpointResolver {
        std.debug.assert(endpoints.len > 0);
        return .{ .endpoints = endpoints };
    }

    fn deinit(self: *EndpointResolver, allocator: std.mem.Allocator) void {
        self.clearResolved(allocator);
    }

    fn next(
        self: *EndpointResolver,
        allocator: std.mem.Allocator,
        resolver: *const net.DNSResolver,
        reachability: ?net.ReachabilityInfo,
        timeout_ms: u32,
    ) (std.mem.Allocator.Error || error{ExhaustedEndpoints})!api.ExtendedEndpoint {
        while (true) {
            if (self.resolved) |resolved| {
                if (self.next_resolved_index < resolved.len) {
                    const endpoint = resolved[self.next_resolved_index];
                    self.next_resolved_index += 1;
                    return endpoint;
                }
                self.clearResolved(allocator);
            }

            if (self.next_endpoint_index >= self.endpoints.len) {
                self.next_endpoint_index = 0;
                return error.ExhaustedEndpoints;
            }
            const source = self.endpoints[self.next_endpoint_index];
            self.next_endpoint_index += 1;
            self.resolved = resolveEndpoint(
                allocator,
                resolver,
                source,
                reachability,
                timeout_ms,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NetworkUnreachable,
                error.ResolutionFailure,
                error.Timeout,
                => {
                    log.writef(.err, "OpenVPN: Unable to resolve {s}: {s}", .{
                        source.address,
                        @errorName(err),
                    });
                    continue;
                },
            };
            self.next_resolved_index = 0;
        }
    }

    fn clearResolved(
        self: *EndpointResolver,
        allocator: std.mem.Allocator,
    ) void {
        if (self.resolved) |resolved| deinitEndpoints(allocator, resolved);
        self.resolved = null;
        self.next_resolved_index = 0;
    }
};

fn resolveEndpoint(
    allocator: std.mem.Allocator,
    resolver: *const net.DNSResolver,
    endpoint: api.ExtendedEndpoint,
    reachability: ?net.ReachabilityInfo,
    timeout_ms: u32,
) net.DNSResolver.Error![]api.ExtendedEndpoint {
    const address = api.Address.parseRaw(endpoint.address) orelse
        return error.ResolutionFailure;
    if (address.isIPAddress()) {
        const mapped = try resolver.resolveAddress(
            allocator,
            endpoint.address,
            reachability,
            timeout_ms,
        );
        defer allocator.free(mapped);
        const mapped_address = api.Address.parseRaw(mapped) orelse
            return error.ResolutionFailure;
        if (!mapped_address.isIPAddress() or
            !isCompatibleAddress(endpoint, mapped_address.family == .v6))
        {
            return error.ResolutionFailure;
        }
        const result = try allocator.alloc(api.ExtendedEndpoint, 1);
        errdefer allocator.free(result);
        result[0] = .{
            .address = try allocator.dupe(u8, mapped),
            .proto = endpoint.proto,
            .owned = true,
        };
        return result;
    }

    const records = try resolver.resolve(
        allocator,
        endpoint.address,
        std.EnumSet(net.DNSResolver.Flag).initEmpty(),
        reachability,
        timeout_ms,
    );
    defer {
        for (records) |record| record.deinit(allocator);
        allocator.free(records);
    }
    var result: std.ArrayList(api.ExtendedEndpoint) = .empty;
    errdefer {
        for (result.items) |*resolved| resolved.deinit(allocator);
        result.deinit(allocator);
    }
    for (records) |record| {
        const resolved_address = api.Address.parseRaw(record.address) orelse continue;
        if (!resolved_address.isIPAddress()) continue;
        if (!isCompatibleAddress(endpoint, record.is_ipv6)) continue;
        try result.append(allocator, .{
            .address = try allocator.dupe(u8, record.address),
            .proto = endpoint.proto,
            .owned = true,
        });
    }
    return result.toOwnedSlice(allocator);
}

fn isCompatibleAddress(endpoint: api.ExtendedEndpoint, is_ipv6: bool) bool {
    return switch (endpoint.proto.socket_type) {
        .udp4, .tcp4 => !is_ipv6,
        .udp6, .tcp6 => is_ipv6,
        .udp, .tcp => true,
    };
}

fn configurationApplyingActiveModules(
    allocator: std.mem.Allocator,
    source: *const api.OpenVPNConfiguration,
    profile: *const api.Profile,
) std.mem.Allocator.Error!api.OpenVPNConfiguration {
    var configuration = source.clone(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson, error.InvalidModel, error.UnsupportedModel => unreachable,
    };
    errdefer configuration.deinit(allocator);

    var add_ipv4 = false;
    var add_ipv6 = false;
    for (profile.modules) |*module| {
        if (!api.isActiveProfileModule(profile, api.moduleId(module))) continue;
        switch (module.*) {
            .IP => |*ip| {
                if (ip.ipv4) |*settings| {
                    add_ipv4 = add_ipv4 or routesDefaultThroughVPN(settings);
                }
                if (ip.ipv6) |*settings| {
                    add_ipv6 = add_ipv6 or routesDefaultThroughVPN(settings);
                }
            },
            else => {},
        }
    }
    try appendRoutingPolicy(allocator, &configuration, .IPv4, add_ipv4);
    try appendRoutingPolicy(allocator, &configuration, .IPv6, add_ipv6);
    return configuration;
}

fn routesDefaultThroughVPN(settings: *const api.IPSettings) bool {
    return containsDefaultRoute(settings.included_routes) and
        !containsDefaultRoute(settings.excluded_routes);
}

fn containsDefaultRoute(routes: []const api.Route) bool {
    for (routes) |route| {
        if (route.destination == null) return true;
    }
    return false;
}

fn appendRoutingPolicy(
    allocator: std.mem.Allocator,
    configuration: *api.OpenVPNConfiguration,
    policy: api.OpenVPNRoutingPolicy,
    should_append: bool,
) std.mem.Allocator.Error!void {
    if (!should_append) return;
    const previous = configuration.routing_policies orelse &.{};
    if (std.mem.indexOfScalar(api.OpenVPNRoutingPolicy, previous, policy) != null)
        return;
    const updated = try allocator.alloc(
        api.OpenVPNRoutingPolicy,
        previous.len + 1,
    );
    @memcpy(updated[0..previous.len], previous);
    updated[previous.len] = policy;
    if (configuration.routing_policies) |owned| allocator.free(owned);
    configuration.routing_policies = updated;
}

fn canChangeStatus(
    current: api.ConnectionStatus,
    next: api.ConnectionStatus,
) bool {
    if (current == next) return false;
    return switch (current) {
        .disconnected => next == .connecting,
        .connecting => next == .connected or
            next == .disconnecting or
            next == .disconnected,
        .connected => next == .disconnecting or next == .disconnected,
        .disconnecting => next == .disconnected,
    };
}

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

fn cloneEndpoint(
    allocator: std.mem.Allocator,
    endpoint: api.ExtendedEndpoint,
) std.mem.Allocator.Error!api.ExtendedEndpoint {
    return .{
        .address = try allocator.dupe(u8, endpoint.address),
        .proto = endpoint.proto,
        .owned = true,
    };
}

fn deinitEndpoints(
    allocator: std.mem.Allocator,
    endpoints: []api.ExtendedEndpoint,
) void {
    for (endpoints) |*endpoint| endpoint.deinit(allocator);
    allocator.free(endpoints);
}

const openvpn_connection_vtable = net.Connection.VTable{
    .start = start,
    .stop = stop,
    .network_change = networkChange,
    .better_path = betterPath,
    .deinit = deinit,
    .looper_finish = looperDidFinish,
};

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

fn looperDidFinish(
    ptr: *anyopaque,
    failure: ?net.Looper.Failure,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.looperDidFinish(failure);
}

fn deinit(ptr: *anyopaque, _: std.mem.Allocator) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.deinit();
}

pub const testing = struct {
    pub fn configurationWithActiveModules(
        allocator: std.mem.Allocator,
        source: *const api.OpenVPNConfiguration,
        profile: *const api.Profile,
    ) std.mem.Allocator.Error!api.OpenVPNConfiguration {
        return configurationApplyingActiveModules(allocator, source, profile);
    }
};
