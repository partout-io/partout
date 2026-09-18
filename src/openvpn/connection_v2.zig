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
const logging_mod = @import("internal/logging.zig");
const processing_mod = @import("internal/processing.zig");
const session_mod = @import("internal/session_v2.zig");
const settings_mod = @import("internal/settings.zig");

const api = core.api;
const log = core.logging;
const openvpn_log = logging_mod;

const AuthToken = auth_mod.AuthToken;
const Looper = net.Looper;
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

const ConnectionError = SessionError || error{
    InvalidEndpoint,
    ModulesAllocation,
    MuxFailure,
    NetworkChanged,
    TunNotAvailable,
};

/// Connection and Session state are confined to the externally owned looper.
/// The owner must deliver every runtime call on that looper, and quiesce all
/// I/O before releasing resources. Creation before publication and destruction
/// after full shutdown may run outside it. Outgoing callbacks must return
/// promptly, never wait for the daemon actor, and never reenter the lifecycle.
const OpenVPNConnection = struct {
    allocator: std.mem.Allocator,
    module_id: api.UUID,
    profile: *const api.Profile,
    connection_options: net.ConnectionOptions,
    session_options: SessionOptions,
    session_events: SessionEvents,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    auth_token: AuthToken,
    endpoints: []api.ExtendedEndpoint,
    cache_dir: []const u8,
    ca_filename: []const u8,

    /// Stable callback sink supplied at creation.
    events: ?net.Connection.Events,
    with_local_options: bool,
    /// Ownership marks an attempt awaiting finalization, even if stopped.
    current_session: ?*Session,
    pending_failure: ?ConnectionError,
    shutdown_reason: net.Connection.ShutdownReason,

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

        const module_id = module.id();
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

        const ca_filename = try api.moduleCacheFilename(
            allocator,
            module_id,
            TLSConstants.ca_filename,
        );
        errdefer allocator.free(ca_filename);

        const fnt = try api.cryptoFunctionTable(context.session_options.backend);

        const created = try allocator.create(OpenVPNConnection);
        var session_options = context.session_options;
        session_options.write_timeout_ms = sandbox.options.link_write_timeout;
        session_options.min_data_count_interval_ms =
            sandbox.options.min_data_count_interval;

        const session_events = SessionEvents{
            .ctx = created,
            .established = sessionEstablished,
            .failed = sessionFailed,
            .data_count = sessionDataCount,
        };

        created.* = .{
            .allocator = allocator,
            .module_id = module_id,
            .profile = sandbox.profile,
            .connection_options = sandbox.options,
            .session_options = session_options,
            .session_events = session_events,
            .configuration = configuration,
            .credentials = credentials,
            .auth_token = .{},
            .endpoints = endpoints,
            .cache_dir = cache_dir,
            .ca_filename = ca_filename,
            .events = sandbox.events,
            .with_local_options = true,
            .current_session = null,
            .pending_failure = null,
            .shutdown_reason = .explicit_stop,
        };
        log.writef(
            .notice,
            "Using OpenVPNConnection v2 (crypto = {s})",
            .{fnt.name},
        );
        return created.asConnection();
    }

    fn destroy(self: *OpenVPNConnection) void {
        log.write(.debug, "Deinit OpenVPNConnection v2");
        self.releaseSession();
        self.auth_token.deinit();
        core.util.freeSlice(api.ExtendedEndpoint, self.allocator, self.endpoints);
        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.ca_filename);
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

    fn allEndpoints(self: *const OpenVPNConnection) []const api.ExtendedEndpoint {
        return self.endpoints;
    }

    fn startV2(
        self: *OpenVPNConnection,
        descriptor: net.LinkDescriptor,
    ) net.ConnectionStartError!bool {
        if (self.current_session != null) {
            log.write(.err, "Ignore start, connection attempt pending");
            return false;
        }

        const session = Session.create(self.allocator, .{
            .looper = descriptor.looper,
            .remote_endpoint = descriptor.endpoint,
            .events = self.session_events,
            .configuration = self.configuration,
            .credentials = self.credentials,
            .auth_token = &self.auth_token,
            .prng = PRNG.system(),
            .caches_directory = self.cache_dir,
            .ca_filename = self.ca_filename,
            .with_local_options = self.with_local_options,
            .options = self.session_options,
        }) catch |err| {
            log.writef(.err, "Unable to create session: {s}", .{@errorName(err)});
            return error.UnableToStart;
        };

        // Install the current attempt.
        self.current_session = session;
        self.reportServerConfiguration(null);

        session.start() catch |err| {
            log.writef(.fault, "Unable to start session: {s}", .{@errorName(err)});
            self.releaseSession();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnableToStart,
            };
        };
        return true;
    }

    fn shutdown(self: *OpenVPNConnection, reason: net.Connection.ShutdownReason) void {
        self.shutdown_reason = reason;
        const session = self.current_session orelse return;
        _ = session.shutdown(.{
            .gracefully = switch (reason) {
                .explicit_stop => true,
                .failure => self.pending_failure != null and self.pending_failure.? == error.NetworkChanged,
            },
        });
    }

    fn stop(
        self: *OpenVPNConnection,
        // FIXME: ###, Remove, handle timeout in daemon
        _: u32,
        _: net.Connection.Events,
    ) void {
        self.finalizeSession();
    }

    fn submitPackets(
        self: *OpenVPNConnection,
        side: net.Side,
        packets: Looper.Packets,
    ) Looper.ReadAction {
        const session = self.current_session orelse return .pause;
        if (self.pending_failure != null) return .pause;
        return session.submitPackets(side, packets);
    }

    fn looperFailed(
        self: *OpenVPNConnection,
        side: net.Side,
        failure: Looper.Failure,
    ) void {
        const session = self.current_session orelse return;
        session.looperFailed(side, failure);
    }

    fn looperTerminated(self: *OpenVPNConnection, failure: ?Looper.Failure) void {
        const session = self.current_session orelse return;
        self.handleSessionFailed(error.LooperTerminated);
        session.looperTerminated(failure);
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
        self.handleConnectionFailure(error.NetworkChanged);
    }

    // MARK: - Session events

    fn isSessionStarted(self: *const OpenVPNConnection) bool {
        const session = self.current_session orelse return false;
        return session.isStarted();
    }

    fn handleSessionEstablished(
        self: *OpenVPNConnection,
        remote_endpoint: api.ExtendedEndpoint,
        remote_options: *const api.OpenVPNConfiguration,
    ) void {
        if (self.pending_failure != null) return;
        std.debug.assert(self.isSessionStarted());
        log.write(.notice, "Session established");
        const address = api.Address.parseRaw(remote_endpoint.address) orelse {
            log.write(.fault, "Unable to parse remote endpoint");
            self.handleConnectionFailure(error.InvalidEndpoint);
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
        self.reportServerConfiguration(remote_options);

        // Build the info object to configure the tunnel.
        const builder = NetworkSettingsBuilder.init(
            &self.configuration,
            remote_options,
        );
        const modules = builder.modules(self.allocator) catch |err| {
            log.writef(.fault, "Unable to allocate settings modules: {s}", .{@errorName(err)});
            self.handleConnectionFailure(error.ModulesAllocation);
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

        const events = self.events orelse return;
        events.established(events.ctx, .{
            .remote_endpoint = remote_endpoint,
            .info = info,
        });
    }

    fn handleSessionFailed(
        self: *OpenVPNConnection,
        cause: SessionError,
    ) void {
        log.writef(.err, "Session failed: {s}", .{@errorName(cause)});
        self.handleConnectionFailure(cause);
    }

    fn handleConnectionFailure(
        self: *OpenVPNConnection,
        cause: ConnectionError,
    ) void {
        const session = self.current_session orelse return;
        if (!session.isActive() or self.pending_failure != null) return;
        log.writef(.err, "Connection failed: {s}", .{@errorName(cause)});
        self.pending_failure = cause;
        // The owner schedules shutdown/detachment/stop. Never reenter the
        // lifecycle here: this callback can run inside TLS.
        const events = self.events orelse return;
        events.failed(events.ctx, .{
            .code = partoutCodeForError(cause),
            .disposition = errorDisposition(cause),
        });
    }

    // MARK: - Reporting

    fn reportServerConfiguration(
        self: *OpenVPNConnection,
        configuration: ?*const api.OpenVPNConfiguration,
    ) void {
        const e = self.events orelse return;
        const cfg = configuration orelse {
            e.set_env(e.ctx, EnvironmentKeys.server_configuration, null);
            return;
        };
        const value = core.util.encodeJsonValue(self.allocator, cfg) catch {
            log.write(.err, "Unable to encode server configuration");
            return;
        };
        defer self.allocator.free(value);
        e.set_env(e.ctx, EnvironmentKeys.server_configuration, value);
    }

    // MARK: - Termination and cleanup

    /// Session ownership marks an attempt awaiting finalization, even after
    /// the Session has stopped. Public status transitions belong to the owner.
    fn finalizeSession(self: *OpenVPNConnection) void {
        const has_session = self.current_session != null;
        const cause = self.pending_failure;
        const recoverable = switch (self.shutdown_reason) {
            .explicit_stop => false,
            .failure => |disposition| disposition == .reconnect,
        };
        self.releaseSession();
        if (!recoverable) {
            self.auth_token.clear();
            self.with_local_options = true;
        } else if (cause != null and cause.? == error.BadCredentialsWithLocalOptions) {
            self.with_local_options = false;
        }
        if (!has_session) return;
        self.reportServerConfiguration(null);
        const events = self.events orelse return;
        // All owned state is settled before the synchronous terminal callback.
        events.stopped(events.ctx);
    }

    /// Resource-only cleanup, also used for startup rollback and destruction.
    /// Runtime shutdown is looper-local; destruction after full shutdown may
    /// run outside the looper. I/O quiescence remains the owner's responsibility.
    fn releaseSession(self: *OpenVPNConnection) void {
        if (self.current_session) |session| {
            if (session.state != .stopped) {
                session.stop();
            }
            self.current_session = null;
            session.destroy();
        }
        self.pending_failure = null;
        self.shutdown_reason = .explicit_stop;
    }
};

// MARK: - Session event callbacks

fn sessionEstablished(
    ctx: ?*anyopaque,
    remote_endpoint: api.ExtendedEndpoint,
    remote_options: *const api.OpenVPNConfiguration,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ctx.?));
    self.handleSessionEstablished(remote_endpoint, remote_options);
}

fn sessionFailed(ctx: ?*anyopaque, cause: SessionError) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ctx.?));
    self.handleSessionFailed(cause);
}

fn sessionDataCount(ctx: ?*anyopaque, data_count: api.DataCount) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ctx.?));
    if (!self.isSessionStarted()) return;
    const events = self.events orelse return;
    events.data_count(events.ctx, data_count);
}

// MARK: - Connection callbacks

fn allEndpoints(ptr: *anyopaque) []const api.ExtendedEndpoint {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    return self.allEndpoints();
}

fn startV2(
    ptr: *anyopaque,
    descriptor: net.LinkDescriptor,
) net.ConnectionStartError!bool {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    return self.startV2(descriptor);
}

fn shutdown(ptr: *anyopaque, reason: net.Connection.ShutdownReason) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.shutdown(reason);
}

fn stop(
    ptr: *anyopaque,
    timeout_ms: u32,
    events: net.Connection.Events,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.stop(timeout_ms, events);
}

fn submitPackets(
    ptr: *anyopaque,
    side: net.Side,
    packets: Looper.Packets,
) Looper.ReadAction {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    return self.submitPackets(side, packets);
}

fn looperFailed(
    ptr: *anyopaque,
    side: net.Side,
    failure: Looper.Failure,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.looperFailed(side, failure);
}

fn looperTerminated(
    ptr: *anyopaque,
    failure: ?Looper.Failure,
) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.looperTerminated(failure);
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

fn destroy(ptr: *anyopaque) void {
    const self: *OpenVPNConnection = @ptrCast(@alignCast(ptr));
    self.destroy();
}

fn legacyStart(
    _: *anyopaque,
    _: net.Connection.Events,
) net.ConnectionStartError!bool {
    @panic("Unimplemented");
}

// MARK: - Vtables

const openvpn_connection_vtable = net.Connection.VTable{
    .endpoints = allEndpoints,
    .start_v2 = startV2,
    .shutdown = shutdown,
    .stop = stop,
    .submit_packets = submitPackets,
    .looper_failed = looperFailed,
    .looper_terminated = looperTerminated,
    .network_change = networkChange,
    .better_path = betterPath,
    .destroy = destroy,
    // FIXME: ###, Deprecated
    .start = legacyStart,
};

// MARK: - Error mapping

fn errorDisposition(cause: ConnectionError) net.Connection.Events.FailureDisposition {
    return switch (cause) {
        error.BadCredentials,
        error.CompressionMismatch,
        error.InvalidPushReply,
        error.MissingCA,
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
        error.TunnelFailure,
        error.TunNotAvailable,
        error.WouldBlock,
        error.WriteIncomplete,
        error.WrongControlDataPrefix,
        => .reconnect,
    };
}

pub const testing = struct {
    pub const Implementation = OpenVPNConnection;

    pub fn isRecoverableError(cause: ConnectionError) bool {
        return errorDisposition(cause) == .reconnect;
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
        error.MissingCA,
        error.TLSFailure,
        => .openVPNTLSFailure,
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
        error.TunnelFailure,
        error.WouldBlock,
        error.WriteIncomplete,
        error.WrongControlDataPrefix,
        => .openVPNConnectionFailure,
    };
}
