// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const auth_mod = @import("auth.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const control_mod = @import("control.zig");
const control_serializers_mod = @import("control_serializers.zig");
const crypto_mod = @import("crypto.zig");
const data_mod = @import("data.zig");
const helpers_mod = @import("helpers.zig");
const packet_mod = @import("packet.zig");
const processing_mod = @import("processing.zig");
const session_context_mod = @import("session_context.zig");
const session_negotiator_mod = @import("session_negotiator.zig");
const tls_mod = @import("tls.zig");

const session_mod = @This();
const api = core.api;
const openvpn_c = helpers_mod.openvpn_c;
const log = core.logging;

const ActiveContext = session_context_mod.ActiveContext;
const ActivePhase = session_context_mod.ActivePhase;
const AuthToken = auth_mod.AuthToken;
const SessionOptions = configuration_mod.SessionOptions;
const ControlChannel = control_mod.ControlChannel(control_serializers_mod.Serializer);
const ControlConstants = constants_mod.Control;
const DataChannel = data_mod.DataChannel;
const DataLink = data_mod.DataLink;
const LinkProcessor = processing_mod.LinkProcessor;
const Looper = net.Looper;
const Negotiator = session_negotiator_mod.Negotiator;
const NegotiationResult = session_negotiator_mod.NegotiationResult;
const OCCPacket = packet_mod.OCCPacket;
const PacketCode = packet_mod.PacketCode;
const PRNG = crypto_mod.PRNG;
const RenegotiationType = session_negotiator_mod.RenegotiationType;
const Serializer = control_serializers_mod.Serializer;
const SessionState = session_context_mod.SessionState;
const TLSWrapper = tls_mod.TLSWrapper;

pub const SessionError = error{
    AckIdsTooLong,
    Backpressure,
    BadCredentials,
    BadCredentialsWithLocalOptions,
    CompressionMismatch,
    ContinuationPushReply,
    ControlChannelFailure,
    CryptoDerivation,
    CryptoEncryption,
    CryptoHMAC,
    CryptoPRNG,
    DataPathFailure,
    EndOfStream,
    InvalidAck,
    InvalidKey,
    InvalidPacketId,
    InvalidPushReply,
    InvalidSessionId,
    LibcFailure,
    LinkFailure,
    LooperTerminated,
    LooperUnavailable,
    MissingCA,
    MissingSessionId,
    NoRouting,
    OOBOutsideQueue,
    OutOfBounds,
    OutOfMemory,
    Overflow,
    PacketTooLarge,
    PeerIdMismatch,
    ServerShutdown,
    SessionMismatch,
    SessionStale,
    TLSFailure,
    Timeout,
    TunnelFailure,
    UnsupportedAlgorithm,
    UnsupportedCompression,
    UnsupportedCryptoBackend,
    WouldBlock,
    WriteIncomplete,
    WrongControlDataPrefix,
};

/// Immutable event sink for facts produced by the protocol engine.
///
/// Values passed to callbacks are borrowed for the duration of the callback.
/// Callbacks run on the looper and must return promptly by transporting facts
/// to the owner's execution context; the owner decides whether and how to stop
/// the Session.
pub const SessionEvents = struct {
    ctx: ?*anyopaque = null,
    established: *const fn (
        ?*anyopaque,
        api.ExtendedEndpoint,
        *const api.OpenVPNConfiguration,
    ) void,
    failed: *const fn (?*anyopaque, SessionError) void,
    data_count: *const fn (?*anyopaque, api.DataCount) void,
};

pub const CreateError = error{
    OutOfMemory,
    InvalidConfiguration,
    OTPRequired,
};
pub const StartError = SessionError || error{SessionAlreadyActive};

/// Implements the OpenVPN protocol over an active link and on a
/// single thread (the looper). Threading and lifetime guarantees
/// are external to this class.
pub const Session = struct {
    allocator: std.mem.Allocator,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    auth_token: *AuthToken,
    prng: PRNG,
    caches_directory: []u8,
    ca_filename: []u8,
    options: SessionOptions,

    // Link interface.
    looper: *Looper,
    remote_endpoint: api.ExtendedEndpoint,
    events: SessionEvents,

    // Internal state.
    state: SessionState,
    control_channel: *ControlChannel,
    negotiation_timer: Looper.Timer,
    ping_timer: Looper.Timer,
    link_processor: *LinkProcessor,

    pub const Init = struct {
        /// I/O strategy.
        looper: *Looper,
        remote_endpoint: api.ExtendedEndpoint,
        events: SessionEvents,
        /// OpenVPN configuration.
        configuration: api.OpenVPNConfiguration,
        credentials: ?api.OpenVPNCredentials,
        /// Borrowed connection state; must outlive this session.
        auth_token: *AuthToken,
        prng: PRNG,
        caches_directory: []const u8,
        ca_filename: []const u8,
        with_local_options: bool = true,
        options: SessionOptions,
    };

    // MARK: - Public API

    pub fn create(allocator: std.mem.Allocator, init: Init) CreateError!*Session {
        log.write(.notice, "Using OpenVPN Session v2");

        const remote_endpoint = try init.remote_endpoint.clone(allocator);
        errdefer remote_endpoint.deinit(allocator);

        var owned_configuration = init.configuration.clone(allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.writef(.fault, "Unable to clone configuration: {s}", .{@errorName(err)});
            return error.InvalidConfiguration;
        };
        errdefer owned_configuration.deinit(allocator);

        var owned_credentials = if (init.credentials) |value|
            try configuration_mod.credentialsForAuthentication(allocator, value)
        else
            null;
        errdefer if (owned_credentials) |*value| value.deinit(allocator);

        const owned_caches_directory = try allocator.dupe(u8, init.caches_directory);
        errdefer allocator.free(owned_caches_directory);

        const owned_ca_filename = try allocator.dupe(u8, init.ca_filename);
        errdefer allocator.free(owned_ca_filename);

        const serializer = Serializer.forConfiguration(
            allocator,
            init.options.backend,
            &owned_configuration,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.writef(.fault, "Unable to create serializer: {s}", .{@errorName(err)});
            return error.InvalidConfiguration;
        };
        const control_channel = try ControlChannel.create(allocator, init.prng, serializer);
        // This also takes care of freeing the now owned serializer on error.
        errdefer control_channel.destroy();

        const link_processor = LinkProcessor.create(
            allocator,
            owned_configuration.xor_method,
            init.remote_endpoint.plainSocketType() == .tcp,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.writef(.fault, "Unable to create link processor: {s}", .{@errorName(err)});
            return error.InvalidConfiguration;
        };
        errdefer link_processor.destroy();

        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .configuration = owned_configuration,
            .credentials = owned_credentials,
            .auth_token = init.auth_token,
            .prng = init.prng,
            .caches_directory = owned_caches_directory,
            .ca_filename = owned_ca_filename,
            .options = init.options,
            .looper = init.looper,
            .remote_endpoint = remote_endpoint,
            .events = init.events,
            .state = .{
                .stopped = .{
                    .with_local_options = init.with_local_options,
                },
            },
            .control_channel = control_channel,
            .negotiation_timer = .{},
            .ping_timer = .{},
            .link_processor = link_processor,
        };
        return self;
    }

    pub fn destroy(self: *Session) void {
        log.write(.debug, "Deinit OpenVPN v2 Session");
        switch (self.state) {
            .stopped => {},
            .active => |active| active.context.destroy(),
        }
        self.control_channel.destroy();
        self.link_processor.destroy();
        self.remote_endpoint.deinit(self.allocator);

        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.caches_directory);
        self.allocator.free(self.ca_filename);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    // MARK: - Public API

    pub fn isActive(self: *const Session) bool {
        return switch (self.state) {
            .stopped => false,
            .active => |active| active.phase != .stopping,
        };
    }

    pub fn isStarting(self: *const Session) bool {
        return switch (self.state) {
            .stopped => false,
            .active => |active| active.phase == .starting,
        };
    }

    pub fn isStarted(self: *const Session) bool {
        return switch (self.state) {
            .stopped => false,
            .active => |active| active.phase == .started,
        };
    }

    pub fn start(self: *Session) StartError!void {
        self.assertLooperThread();
        const idle = switch (self.state) {
            .stopped => |context| context,
            .active => {
                log.write(.err, "Session is not stopped");
                // Swift calls this operationCancelled. Name the concrete Zig
                // state instead: this is not an in-place restart.
                return error.SessionAlreadyActive;
            },
        };
        log.write(.info, "Start VPN session");
        const data_link = DataLink.init(
            self.allocator,
            self.looper,
            self.link_processor,
            self,
            .{
                .data_channel = Session.dataChannelForKey,
                .report_inbound_data_count = Session.reportInboundDataCount,
                .report_outbound_data_count = Session.reportOutboundDataCount,
            },
        );
        const active_context = try ActiveContext.create(
            self.allocator,
            data_link,
            idle.with_local_options,
            self.remote_endpoint,
        );
        self.state = .{ .active = .{
            .phase = .starting,
            .context = active_context,
        } };
        self.startNegotiation() catch |err| {
            self.cancelTimers();
            active_context.destroy();
            self.state = .{ .stopped = idle };
            return err;
        };
    }

    pub fn submitPackets(
        self: *Session,
        side: net.Side,
        packets: Looper.Packets,
    ) Looper.ReadAction {
        self.assertLooperThread();
        const active = self.state.activeState() orelse return .pause;
        if (active.phase == .stopping) {
            log.write(.debug, "Ignore packets while stopping");
            return .pause;
        }
        switch (side) {
            .link => {
                self.receiveLink(packets) catch |err| {
                    self.recordFailure(err);
                    self.reportFailure(err);
                    return .pause;
                };
            },
            .tun => {
                self.receiveTunnel(packets) catch |err| {
                    self.recordFailure(err);
                    self.reportFailure(err);
                    return .pause;
                };
            },
        }
        return .keep;
    }

    pub fn looperFailed(self: *Session, side: net.Side, failure: Looper.Failure) void {
        self.assertLooperThread();
        const fallback = switch (side) {
            .link => error.LinkFailure,
            .tun => error.TunnelFailure,
        };
        const cause = sideFailureError(failure, fallback);
        self.reportFailure(cause);
    }

    /// Routes the externally owned looper's terminal callback into the
    /// session. The owner must call this synchronously from `Looper.OnFinish`
    /// while the Session is alive, and must stop forwarding before `destroy`.
    pub fn looperTerminated(self: *Session, failure: ?Looper.Failure) void {
        self.assertLooperThread();
        if (failure) |value| switch (value) {
            .user => |cause| log.writef(.err, "Session looper finished with error: {s}", .{
                @errorName(cause),
            }),
            .io => |details| log.writef(.err, "Session looper finished with error: {s}", .{
                @errorName(details.cause),
            }),
            .system => |cause| log.writef(.err, "Session looper finished with error: {s}", .{
                @errorName(cause),
            }),
            .wait => |code| log.writef(.err, "Session looper finished with error: wait({d})", .{
                code,
            }),
        };
        self.stop();
    }

    pub const ShutdownRequest = struct {
        gracefully: bool,
    };

    pub fn shutdown(self: *Session, request: ShutdownRequest) bool {
        self.assertLooperThread();
        // Negotiation may arm a check before a later startup operation fails
        // and restores .stopped. Always sever timer callback contexts before
        // deciding whether an active shutdown transaction is needed.
        self.cancelTimers();
        const active = self.state.activeState() orelse {
            log.write(.debug, "Ignore stop request, stopped or already stopping");
            return false;
        };
        if (active.phase == .stopping) {
            // Resume a transaction interrupted by looper teardown or a
            // rejected detach without introducing a second lifecycle state.
            log.write(.debug, "Resume stop request already in progress");
            return true;
        }
        active.phase = .stopping;

        if (shouldSendExitNotification(request.gracefully)) {
            log.write(.info, "Shut down session gracefully");
            self.sendExitPacket() catch |err| {
                log.writef(.err, "Unable to send exit packet: {s}", .{@errorName(err)});
            };
        } else {
            log.write(.err, "Shut down session due to failure");
        }
        return true;
    }

    pub fn stop(self: *Session) void {
        self.assertLooperThread();
        const active = switch (self.state) {
            .stopped => {
                return;
            },
            .active => |value| value,
        };
        // Terminal looper failures bypass shutdown(), so cancel both
        // queue-owned timers here as well as in the normal shutdown path.
        self.cancelTimers();
        const with_local_options = active.context.with_local_options;
        active.context.destroy();
        self.state = .{ .stopped = .{
            .with_local_options = with_local_options,
        } };
    }

    fn assertLooperThread(self: *const Session) void {
        if (!self.looper.isOnQueue()) {
            @panic("Session operation outside looper thread");
        }
    }

    // MARK: Lifecycle

    fn reportFailure(self: *Session, cause: SessionError) void {
        self.events.failed(self.events.ctx, cause);
    }

    fn recordFailure(self: *Session, cause: SessionError) void {
        if (cause != error.BadCredentialsWithLocalOptions) return;
        const context = self.state.activeContext() orelse return;
        context.with_local_options = false;
    }

    fn sendExitPacket(self: *Session) !void {
        const context = self.state.activeContext() orelse return;
        if (context.remote_endpoint.plainSocketType() != .udp) return;
        const pair = context.current_data_pair orelse return;
        log.write(.info, "Send OCCPacket exit");
        const exit = OCCPacket.exit.serialized();
        const packet: []const u8 = &exit;
        // Zero timeout sends OOB without waiting.
        // FIXME: Honor the caller's stop timeout with daemon-coordinated retries
        // before detaching LINK; this single OOB attempt currently ignores it.
        try pair.send(&.{packet}, null, 0);
        log.write(.info, "Sent OCCPacket correctly");
    }

    fn cancelTimers(self: *Session) void {
        self.looper.cancelTimer(&self.negotiation_timer);
        self.looper.cancelTimer(&self.ping_timer);
    }

    // MARK: Packet I/O

    fn receiveLink(self: *Session, packets: Looper.Packets) SessionError!void {
        var processed = try self.link_processor.processInbound(packets);
        defer processed.deinit();

        const context = self.state.activeContext() orelse return;
        context.last_received_ns = core.concurrency.monotonicNs();
        var negotiator = context.currentNegotiator() orelse {
            @panic("Active session received link packets without a negotiator");
        };
        if (negotiator.shouldRenegotiate())
            negotiator = try self.startRenegotiation(negotiator, .client);

        var grouped = [_]std.ArrayList([]const u8){.empty} **
            ControlConstants.number_of_keys;
        defer for (&grouped) |*list| list.deinit(self.allocator);
        for (processed.packets()) |packet| {
            if (packet.len == 0) {
                log.write(.err, "Dropped malformed packet (missing opcode)");
                continue;
            }
            const code_value = packet[0] >> 3;
            const code = PacketCode.fromRaw(code_value) orelse {
                log.writef(.err, "Dropped malformed packet (unknown code: {d})", .{
                    code_value,
                });
                continue;
            };
            if (code == .dataV2 and packet.len <= openvpn_c.OpenVPNPacketPeerIdLength) {
                log.write(.err, "Dropped malformed packet (missing peerId)");
                continue;
            }

            if (code == .dataV1 or code == .dataV2) {
                const key = packet[0] & 0b111;
                if (context.dataChannel(key) == null) {
                    log.writef(.err, "Data: Channel with key {d} not found", .{key});
                    continue;
                }
                try grouped[key].append(self.allocator, packet);
                continue;
            }

            try self.processDataPackets(context, &grouped);
            var parsed = self.control_channel.readInboundPacket(packet, 0) catch |err| {
                log.writef(.err, "Dropped malformed packet: {s}", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();
            if (parsed.code == .ackV1) continue;
            switch (code) {
                .hardResetServerV2 => {
                    if (negotiator.isConnected()) {
                        log.write(.notice, "OpenVPN server requested a fresh session; reconnecting");
                        // Swift reports recoverable(staleSession) here. A connected
                        // session cannot accept a fresh server session ID in place.
                        return error.SessionStale;
                    }
                },
                .softResetV1 => {
                    negotiator = try self.startRenegotiation(negotiator, .server);
                },
                else => {},
            }
            try negotiator.sendAck(&parsed);
            const inbound = try self.control_channel.enqueueInboundPacket(parsed.move());
            defer {
                for (inbound) |*owned| owned.deinit();
                self.allocator.free(inbound);
            }
            for (inbound) |*owned| {
                log.writef(.debug, "Handle packet: {d}", .{owned.packetId()});
                if (try negotiator.handleControlPacket(owned)) |result|
                    try self.didNegotiate(result);
            }
        }
        try self.processDataPackets(context, &grouped);
    }

    fn processDataPackets(
        _: Session,
        context: *ActiveContext,
        grouped: *[ControlConstants.number_of_keys]std.ArrayList([]const u8),
    ) !void {
        const pair = context.current_data_pair orelse {
            for (grouped) |*list| list.clearRetainingCapacity();
            return;
        };
        for (grouped, 0..) |*list, key| {
            if (list.items.len > 0) try pair.receive(list.items, @intCast(key));
            list.clearRetainingCapacity();
        }
    }

    fn receiveTunnel(self: *Session, packets: []const []const u8) SessionError!void {
        const context = self.state.activeContext() orelse return;
        const pair = context.current_data_pair orelse return;
        try self.checkPingTimeout(context);
        try pair.send(packets, null, null);
    }

    // MARK: Negotiation

    fn startNegotiation(self: *Session) !void {
        log.write(.info, "Start negotiation");
        const context = self.state.activeContext() orelse
            @panic("Cannot start negotiation while the session is stopped");
        const tls = try TLSWrapper.create(self.allocator, .{
            .backend = self.options.backend,
            .caches_directory = self.caches_directory,
            .ca_filename = self.ca_filename,
            .configuration = &self.configuration,
            .verification = .{
                .context = self,
                .callback = Session.onTLSVerificationFailure,
            },
        });
        var tls_transferred = false;
        errdefer if (!tls_transferred) tls.destroy();
        const negotiator = try Negotiator.create(self.allocator, .{
            .looper = self.looper,
            .link_processor = self.link_processor,
            .remote_endpoint = &context.remote_endpoint,
            .channel = self.control_channel,
            .prng = self.prng,
            .tls = tls,
            .options = .{
                .configuration = &self.configuration,
                .credentials = if (self.credentials) |*value| value else null,
                .auth_token = self.auth_token,
                .with_local_options = context.with_local_options,
                .session_options = self.options,
                .callback_context = self,
                .schedule_negotiation_check = Session.scheduleNegotiationCheck,
            },
        });
        tls_transferred = true;
        context.addNegotiator(negotiator);
        try negotiator.start();
    }

    fn startRenegotiation(
        self: *Session,
        previous: *Negotiator,
        initiated_by: RenegotiationType,
    ) !*Negotiator {
        if (previous.isRenegotiating()) {
            log.write(.err, "Renegotiation already in progress");
            return previous;
        }
        log.write(
            .notice,
            if (initiated_by == .server)
                "Renegotiation request from server"
            else
                "Renegotiation request from client",
        );
        const context = self.state.activeContext() orelse
            @panic("Cannot start renegotiation while the session is stopped");
        const negotiator = try previous.forRenegotiation(initiated_by);
        // A premature SOFT_RESET reuses the current negotiator without restarting it.
        if (negotiator == previous) return previous;
        context.addNegotiator(negotiator);
        try negotiator.start();
        return negotiator;
    }

    fn didNegotiate(self: *Session, result: NegotiationResult) !void {
        var owns_data_channel = true;
        errdefer if (owns_data_channel) result.data_channel.destroy();
        // Swift silently drops a negotiation completion after active state is
        // gone. Treat it as stale instead: the negotiated data has no context
        // to commit into, so propagate the recoverable reconnect signal.
        const active = self.state.activeState() orelse return error.SessionStale;
        const context = active.context;
        log.writef(.info, "Negotiation succeeded, set key {d} as current", .{result.key});
        var reply = try result.push_reply.clone(self.allocator);
        var owns_reply = true;
        errdefer if (owns_reply) reply.deinit(self.allocator);
        log.writef(.info, "Replace key {d} with new data channel", .{
            result.data_channel.key,
        });
        try context.setDataChannel(result.data_channel, result.key);
        owns_data_channel = false;
        context.setPushReply(reply);
        owns_reply = false;
        context.removeOldNegotiators();
        const negotiator_keys = context.negotiatorKeys();
        log.writef(.info, "Negotiators: {any}", .{negotiator_keys.slice()});
        const data_keys = context.dataKeys();
        log.writef(.info, "Data channels: {any}", .{data_keys.slice()});
        if (active.phase == .started) return;
        active.phase = .started;
        try self.scheduleNextPing(context);
        self.events.established(
            self.events.ctx,
            context.remote_endpoint,
            &context.push_reply.?.options,
        );
    }

    // MARK: Callbacks, timers and keep-alive

    fn onTLSVerificationFailure(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.reportFailure(error.TLSFailure);
    }

    fn scheduleNegotiationCheck(raw: ?*anyopaque, delay_ms: u64) Looper.SubmissionError!void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.looper.scheduleReplacing(
            &self.negotiation_timer,
            delay_ms,
            .{ .context = self, .callback = onNegotiationTimer },
        );
    }

    fn scheduleNextPing(self: *Session, context: *ActiveContext) !void {
        const delay_ms = self.keepAliveIntervalMs(context) orelse
            self.options.ping_timeout_check_interval_ms;
        log.logTimeMs(.debug, "Schedule ping check after ", delay_ms);
        try self.looper.scheduleReplacing(
            &self.ping_timer,
            delay_ms,
            .{ .context = self, .callback = onPingTimer },
        );
    }

    fn onNegotiationTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.checkNegotiation() catch |err| {
            self.reportFailure(err);
        };
    }

    fn checkNegotiation(self: *Session) !void {
        const active = self.state.activeState() orelse return;
        if (active.phase == .stopping) return;
        const context = active.context;
        const negotiator = context.currentNegotiator() orelse
            @panic("Active session negotiation timer fired without a negotiator");
        try negotiator.checkNegotiation();
    }

    fn onPingTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.ping() catch |err| {
            self.reportFailure(err);
        };
    }

    fn ping(self: *Session) !void {
        const context = self.state.activeContext() orelse {
            log.write(.debug, "Ping cancelled, session stopped");
            return;
        };
        const pair = context.current_data_pair orelse {
            log.write(.debug, "Ping cancelled, no data link");
            return;
        };
        log.write(.debug, "Run ping check");
        try self.checkPingTimeout(context);
        if (self.keepAliveIntervalMs(context) != null) {
            log.write(.debug, "Send ping");
            const ping_packet: []const u8 = &constants_mod.Data.ping_string;
            try pair.send(&.{ping_packet}, null, null);
        }
        try self.scheduleNextPing(context);
    }

    fn checkPingTimeout(self: *Session, context: *ActiveContext) !void {
        const last_received = context.last_received_ns orelse return;
        const deadline = core.concurrency.deadlineAfterMs(
            last_received,
            self.keepAliveTimeoutMs(context),
        );
        if (core.concurrency.monotonicNs() > deadline)
            return error.Timeout;
    }

    fn keepAliveIntervalMs(self: *Session, context: *ActiveContext) ?u64 {
        const pushed = if (context.push_reply) |reply|
            reply.options.keep_alive_interval
        else
            null;
        return keepAliveMs(pushed, self.configuration.keep_alive_interval);
    }

    fn keepAliveTimeoutMs(self: *Session, context: *ActiveContext) u64 {
        const pushed = if (context.push_reply) |reply|
            reply.options.keep_alive_timeout
        else
            null;
        return keepAliveMs(pushed, self.configuration.keep_alive_timeout) orelse
            self.options.ping_timeout_ms;
    }

    fn keepAliveMs(pushed: ?f64, configured: ?f64) ?u64 {
        for ([_]?f64{ pushed, configured }) |candidate| {
            const seconds = candidate orelse continue;
            if (seconds > 0) return core.util.secondsToMilliseconds(seconds);
        }
        return null;
    }

    // MARK: Data callbacks

    fn dataChannelForKey(raw: ?*anyopaque, key: u8) ?*DataChannel {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return null;
        return context.dataChannel(key);
    }

    fn reportInboundDataCount(raw: ?*anyopaque, count: usize) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return;
        self.addDataCount(context, &context.data_count.inbound, count);
    }

    fn reportOutboundDataCount(raw: ?*anyopaque, count: usize) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return;
        self.addDataCount(context, &context.data_count.outbound, count);
    }

    fn addDataCount(
        self: *Session,
        context: *ActiveContext,
        total: *u64,
        count: usize,
    ) void {
        total.* = std.math.add(u64, total.*, @intCast(count)) catch std.math.maxInt(u64);
        self.reportCurrentDataCount(context);
    }

    fn reportCurrentDataCount(self: *Session, context: *ActiveContext) void {
        const now = core.concurrency.monotonicNs();
        if (context.last_data_count_ns) |last| {
            const next = core.concurrency.deadlineAfterMs(
                last,
                self.options.min_data_count_interval_ms,
            );
            if (self.options.min_data_count_interval_ms > 0 and now < next) return;
        }
        context.last_data_count_ns = now;
        self.events.data_count(self.events.ctx, .{
            .received = context.data_count.inbound,
            .sent = context.data_count.outbound,
        });
    }
};

fn sideFailureError(failure: Looper.Failure, fallback: SessionError) SessionError {
    return switch (failure) {
        .user => |cause| blk: {
            inline for (@typeInfo(SessionError).error_set.?) |entry| {
                const session_error = @field(SessionError, entry.name);
                if (cause == session_error) break :blk session_error;
            }
            log.writef(.err, "Looper callback failed: {s}", .{@errorName(cause)});
            break :blk fallback;
        },
        .io, .system, .wait => fallback,
    };
}

fn shouldSendExitNotification(gracefully: bool) bool {
    return gracefully;
}

pub const testing = struct {
    pub const sideFailureError = session_mod.sideFailureError;
    pub const shouldSendExitNotification = session_mod.shouldSendExitNotification;

    pub fn reportFailure(session: *Session, cause: SessionError) void {
        session.reportFailure(cause);
    }
};
