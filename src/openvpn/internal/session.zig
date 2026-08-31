// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const AuthToken = @import("auth.zig").AuthToken;
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
const SessionOptions = configuration_mod.SessionOptions;
const ControlChannel = control_mod.ControlChannel(control_serializers_mod.Serializer);
const ControlConstants = constants_mod.Control;
const DataChannel = data_mod.DataChannel;
const DataLink = data_mod.DataLink;
const LinkProcessor = processing_mod.LinkProcessor;
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
    TransformFailure,
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
    context: ?*anyopaque = null,
    established: *const fn (
        ?*anyopaque,
        *anyopaque,
        api.ExtendedEndpoint,
        *const api.OpenVPNConfiguration,
    ) void,
    failed: *const fn (?*anyopaque, *anyopaque, SessionError) void,
    data_count: *const fn (?*anyopaque, *anyopaque, api.DataCount) void,
};

pub const CreateError = error{
    OutOfMemory,
    InvalidConfiguration,
    OTPRequired,
} || configuration_mod.ValidationError;

pub const SetLinkError = processing_mod.ProcessorError || net.Looper.AttachError || error{LinkFailure};
pub const SetTunnelError = net.Looper.AttachError;
pub const ShutdownError = net.Looper.DetachError || error{UnableToShutdown};

/// Default V3 OpenVPN session implementation.
///
/// `Session` is heap-only: callbacks borrow this stable address until their
/// looper attachment or timer is cancelled. Its `Looper` is borrowed for the
/// same lifetime. Mutable protocol state is confined to `on_queue`; its owner
/// retains lifecycle policy.
pub const Session = struct {
    allocator: std.mem.Allocator,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    auth_token: ?*AuthToken,
    prng: PRNG,
    caches_directory: []u8,
    ca_filename: []u8,
    options: SessionOptions,

    looper: *net.Looper,
    events: SessionEvents,
    on_queue: SessionOnQueue,

    pub const Init = struct {
        looper: *net.Looper,
        events: SessionEvents,
        configuration: api.OpenVPNConfiguration,
        credentials: ?api.OpenVPNCredentials,
        /// Borrowed connection state; must outlive this session.
        auth_token: ?*AuthToken = null,
        prng: PRNG,
        caches_directory: []const u8,
        ca_filename: []const u8,
        with_local_options: bool = true,
        options: SessionOptions,
    };

    // MARK: - Public API

    pub fn create(allocator: std.mem.Allocator, init: Init) CreateError!*Session {
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
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
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
            .events = init.events,
            .on_queue = SessionOnQueue.init(
                self,
                control_channel,
                init.with_local_options,
            ),
        };
        errdefer self.on_queue.deinit();
        return self;
    }

    /// Must run outside every looper and event callback while the borrowed
    /// looper remains alive and running. This does not stop or deinitialize the
    /// looper.
    pub fn destroy(self: *Session) void {
        if (self.looper.isOnQueue())
            @panic("Session.destroy() must run outside looper callbacks");

        log.write(.debug, "Deinit OpenVPNSession");
        self.shutdown(true, 0) catch |err| {
            log.writef(.fault, "Unable to detach Session before destruction: {s}", .{
                @errorName(err),
            });
            @panic("Session.destroy() cannot release an attached session");
        };
        self.on_queue.deinit();
        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.caches_directory);
        self.allocator.free(self.ca_filename);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn setLink(
        self: *Session,
        descriptor: net.Looper.Descriptor,
        remote_endpoint: api.ExtendedEndpoint,
    ) SetLinkError!void {
        var descriptor_transferred = false;
        defer if (!descriptor_transferred) descriptor.io.cleanup();

        if (self.looper.isOnQueue()) return error.ReentrantCall;
        if (self.looper.isLinkAttached()) {
            log.write(.err, "Link interface already set");
            return;
        }

        const processor = try LinkProcessor.create(
            self.allocator,
            self.configuration.xor_method,
            remote_endpoint.plainSocketType() == .tcp,
        );
        var owns_processor = true;
        errdefer if (owns_processor) processor.destroy();
        self.performOnQueue(
            void,
            processor,
            SessionOnQueue.installLinkProcessor,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.writef(.fault, "Unable to install link processor: {s}", .{@errorName(err)});
            return error.LinkFailure;
        };
        owns_processor = false;
        errdefer self.performOnQueue(
            void,
            processor,
            SessionOnQueue.discardLinkProcessor,
        ) catch {};

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
        descriptor_transferred = true;
        errdefer self.looper.detach(.link) catch {};

        // Initiate the session on the attached link.
        self.performOnQueue(void, remote_endpoint, SessionOnQueue.setLink) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            log.writef(.fault, "Unable to set link: {s}", .{@errorName(err)});
            return error.LinkFailure;
        };
    }

    pub fn setTunnel(
        self: *Session,
        descriptor: net.Looper.Descriptor,
    ) SetTunnelError!void {
        var descriptor_transferred = false;
        defer if (!descriptor_transferred) descriptor.io.cleanup();

        if (self.looper.isOnQueue()) return error.ReentrantCall;
        if (!self.looper.isLinkAttached()) {
            log.write(.err, "Set link interface first");
            return;
        }
        if (self.looper.isTunAttached()) {
            log.write(.err, "Tunnel interface already set");
            return;
        }
        log.write(.info, "Attach TUN");
        try self.looper.attach(.{
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
        });
        descriptor_transferred = true;
    }

    /// Prepares state on the looper, detaches from this external thread, then
    /// finishes state on the looper.
    ///
    /// Swift owns its looper and logs any perform failure here. Zig's
    /// looper is externally owned: LooperUnavailable means OnFinish
    /// through looperTerminated owns finalization, so do not shut down
    /// twice (return early on that error).
    pub fn shutdown(
        self: *Session,
        gracefully: bool,
        timeout_ms: ?u64,
    ) ShutdownError!void {
        if (self.looper.isOnQueue()) return error.ReentrantCall;
        const request = ShutdownRequest{
            .gracefully = gracefully,
            .timeout_ms = timeout_ms,
        };
        const should_shutdown = self.performOnQueue(
            bool,
            request,
            SessionOnQueue.prepareShutdown,
        ) catch |err| {
            if (err == error.LooperUnavailable) return;
            log.writef(.err, "Unable to shut down session on looper queue: {s}", .{
                @errorName(err),
            });
            return error.UnableToShutdown;
        };
        // Another shutdown request is already in progress.
        if (!should_shutdown) return;
        // These synchronous commands are caller-owned and allocation-free.
        // Never release the Session state until every attached side has dropped
        // its callbacks and borrowed native I/O.
        if (self.looper.isTunAttached()) self.looper.detach(.tun) catch |err| switch (err) {
            error.LooperUnavailable => return,
            error.ReentrantCall => return err,
        };
        if (self.looper.isLinkAttached()) self.looper.detach(.link) catch |err| switch (err) {
            error.LooperUnavailable => return,
            error.ReentrantCall => return err,
        };
        self.performOnQueue(void, gracefully, SessionOnQueue.finishShutdown) catch |err| {
            if (err == error.LooperUnavailable) return;
            log.writef(.err, "Unable to finish shutdown on looper queue: {s}", .{
                @errorName(err),
            });
            return error.UnableToShutdown;
        };
    }

    // MARK: - From looper thread

    /// Routes the externally owned looper's terminal callback into the
    /// session. The owner must call this synchronously from `Looper.OnFinish`
    /// while the Session is alive, and must stop forwarding before `destroy`.
    pub fn looperTerminated(self: *Session, failure: ?net.Looper.Failure) void {
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
        self.onQueue().finishShutdown(failure == null);
    }

    fn reportFailure(self: *Session, cause: SessionError) void {
        self.events.failed(self.events.context, self, cause);
    }

    // MARK: - Callback boundaries

    fn onLinkRead(
        raw: ?*anyopaque,
        packets: net.Looper.Packets,
    ) SessionError!net.Looper.ReadAction {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const on_queue = self.onQueue();
        on_queue.receiveLink(packets) catch |err| {
            on_queue.recordFailure(err);
            return err;
        };
        return .keep;
    }

    fn onLinkFailure(raw: ?*anyopaque, failure: net.Looper.Failure) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.reportFailure(sideFailureError(failure, error.LinkFailure));
    }

    fn onTunnelRead(
        raw: ?*anyopaque,
        packets: net.Looper.Packets,
    ) SessionError!net.Looper.ReadAction {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.onQueue().receiveTunnel(packets);
        return .keep;
    }

    fn onTunnelFailure(raw: ?*anyopaque, failure: net.Looper.Failure) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.reportFailure(sideFailureError(failure, error.TunnelFailure));
    }

    fn onTLSVerificationFailure(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.reportFailure(error.TLSFailure);
    }

    fn scheduleNegotiationCheck(
        raw: ?*anyopaque,
        delay_ms: u64,
    ) net.Looper.ScheduleTimerError!void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.onQueue().scheduleNegotiationCheck(delay_ms);
    }

    fn dataChannelForKey(raw: ?*anyopaque, key: u8) ?*DataChannel {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        return self.onQueue().dataChannelForKey(key);
    }

    fn reportInboundDataCount(raw: ?*anyopaque, count: usize) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.onQueue().reportInboundDataCount(count);
    }

    fn reportOutboundDataCount(raw: ?*anyopaque, count: usize) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.onQueue().reportOutboundDataCount(count);
    }

    // MARK: - Private helpers

    fn performOnQueue(
        self: *Session,
        comptime Result: type,
        arguments: anytype,
        comptime callback: anytype,
    ) !Result {
        const Arguments = @TypeOf(arguments);
        const Request = struct {
            session: *Session,
            arguments: Arguments,

            fn run(raw: ?*anyopaque) anyerror!Result {
                const request: *@This() = @ptrCast(@alignCast(raw.?));
                return callback(request.session.onQueue(), request.arguments);
            }
        };
        var request = Request{ .session = self, .arguments = arguments };
        return try self.looper.perform(Result, &request, Request.run);
    }

    fn onQueue(self: *Session) *SessionOnQueue {
        std.debug.assert(self.looper.isOnQueue());
        return &self.on_queue;
    }

    const ShutdownRequest = struct {
        gracefully: bool,
        timeout_ms: ?u64,
    };
};

// MARK: - On queue

/// Owns mutable protocol state confined to the looper. It is created before
/// callbacks can run and deinitialized after timers and looper callbacks have
/// drained. Queue callbacks re-enter through `Session.onQueue`.
const SessionOnQueue = struct {
    session: *Session,
    control_channel: *ControlChannel,
    negotiation_timer: net.Looper.Timer,
    ping_timer: net.Looper.Timer,
    state: SessionState,
    link_processor: ?*LinkProcessor,

    fn init(
        session: *Session,
        control_channel: *ControlChannel,
        with_local_options: bool,
    ) SessionOnQueue {
        return .{
            .session = session,
            .control_channel = control_channel,
            .negotiation_timer = .{},
            .ping_timer = .{},
            .state = .{
                .stopped = .{
                    .with_local_options = with_local_options,
                },
            },
            .link_processor = null,
        };
    }

    fn deinit(self: *SessionOnQueue) void {
        switch (self.state) {
            .stopped => {},
            .active => |active| active.context.destroy(),
        }
        self.clearLinkProcessor();
        self.control_channel.destroy();
    }

    fn cancelTimers(self: *SessionOnQueue) void {
        self.session.looper.cancelTimer(&self.negotiation_timer);
        self.session.looper.cancelTimer(&self.ping_timer);
    }

    // MARK: Lifecycle

    fn installLinkProcessor(
        self: *SessionOnQueue,
        processor: *LinkProcessor,
    ) void {
        if (self.link_processor != null)
            @panic("Session link processor is already installed");
        self.link_processor = processor;
    }

    fn discardLinkProcessor(
        self: *SessionOnQueue,
        processor: *LinkProcessor,
    ) void {
        if (self.link_processor) |installed| {
            if (installed != processor)
                @panic("Session link processor changed before rollback");
            self.clearLinkProcessor();
        }
    }

    fn clearLinkProcessor(self: *SessionOnQueue) void {
        if (self.link_processor) |processor| processor.destroy();
        self.link_processor = null;
    }

    fn setLink(self: *SessionOnQueue, remote_endpoint: api.ExtendedEndpoint) !void {
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
        const processor = self.link_processor orelse
            @panic("Session cannot start before its link processor is configured");
        const data_link = DataLink.init(
            self.session.allocator,
            self.session.looper,
            processor,
            self.session,
            .{
                .data_channel = Session.dataChannelForKey,
                .report_inbound_data_count = Session.reportInboundDataCount,
                .report_outbound_data_count = Session.reportOutboundDataCount,
            },
        );
        const active_context = try ActiveContext.create(
            self.session.allocator,
            data_link,
            idle.with_local_options,
            remote_endpoint,
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

    fn prepareShutdown(self: *SessionOnQueue, request: Session.ShutdownRequest) bool {
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
            self.sendExitPacket(
                request.timeout_ms orelse self.session.options.write_timeout_ms,
            ) catch |err| {
                log.writef(.err, "Unable to send exit packet: {s}", .{@errorName(err)});
            };
        } else {
            log.write(.err, "Shut down session due to failure");
        }
        return true;
    }

    fn finishShutdown(self: *SessionOnQueue, _: bool) void {
        const active = switch (self.state) {
            .stopped => {
                self.clearLinkProcessor();
                return;
            },
            .active => |value| value,
        };
        // Terminal looper failures bypass prepareShutdown(), so cancel both
        // queue-owned timers here as well as in the normal shutdown path.
        self.cancelTimers();
        const with_local_options = active.context.with_local_options;
        active.context.destroy();
        self.state = .{ .stopped = .{
            .with_local_options = with_local_options,
        } };
        self.clearLinkProcessor();
    }

    fn recordFailure(self: *SessionOnQueue, cause: SessionError) void {
        if (cause != error.BadCredentialsWithLocalOptions) return;
        const context = self.state.activeContext() orelse return;
        context.with_local_options = false;
    }

    fn sendExitPacket(self: *SessionOnQueue, timeout_ms: u64) !void {
        const context = self.state.activeContext() orelse return;
        if (context.remote_endpoint.plainSocketType() != .udp) return;
        const pair = context.current_data_pair orelse return;
        log.write(.info, "Send OCCPacket exit");
        const exit = OCCPacket.exit.serialized();
        const packet: []const u8 = &exit;
        try pair.send(&.{packet}, null, timeout_ms);
        log.write(.info, "Sent OCCPacket correctly");
    }

    // MARK: Packet I/O

    fn receiveLink(self: *SessionOnQueue, packets: net.Looper.Packets) SessionError!void {
        const processor = self.link_processor orelse return;
        var processed = try processor.processInbound(packets);
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
        defer for (&grouped) |*list| list.deinit(self.session.allocator);
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
                try grouped[key].append(self.session.allocator, packet);
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
                self.session.allocator.free(inbound);
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
        _: SessionOnQueue,
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

    fn receiveTunnel(self: *SessionOnQueue, packets: []const []const u8) SessionError!void {
        const context = self.state.activeContext() orelse return;
        const pair = context.current_data_pair orelse return;
        try self.checkPingTimeout(context);
        try pair.send(packets, null, null);
    }

    // MARK: Negotiation

    fn startNegotiation(self: *SessionOnQueue) !void {
        log.write(.info, "Start negotiation");
        const context = self.state.activeContext() orelse
            @panic("Cannot start negotiation while the session is stopped");
        const tls = try TLSWrapper.create(self.session.allocator, .{
            .backend = self.session.options.backend,
            .caches_directory = self.session.caches_directory,
            .ca_filename = self.session.ca_filename,
            .configuration = &self.session.configuration,
            .verification = .{
                .context = self.session,
                .callback = Session.onTLSVerificationFailure,
            },
        });
        var tls_transferred = false;
        errdefer if (!tls_transferred) tls.destroy();
        const negotiator = try Negotiator.create(self.session.allocator, .{
            .looper = self.session.looper,
            .link_processor = self.link_processor orelse
                @panic("Cannot start negotiation before the link processor is configured"),
            .remote_endpoint = &context.remote_endpoint,
            .channel = self.control_channel,
            .prng = self.session.prng,
            .tls = tls,
            .options = .{
                .configuration = &self.session.configuration,
                .credentials = if (self.session.credentials) |*value| value else null,
                .auth_token = self.session.auth_token,
                .with_local_options = context.with_local_options,
                .session_options = self.session.options,
                .callback_context = self.session,
                .schedule_negotiation_check = Session.scheduleNegotiationCheck,
            },
        });
        tls_transferred = true;
        context.addNegotiator(negotiator);
        try negotiator.start();
    }

    fn startRenegotiation(
        self: *SessionOnQueue,
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
        context.addNegotiator(negotiator);
        try negotiator.start();
        return negotiator;
    }

    fn didNegotiate(
        self: *SessionOnQueue,
        result: NegotiationResult,
    ) !void {
        var owns_data_channel = true;
        errdefer if (owns_data_channel) result.data_channel.destroy();
        // Swift silently drops a negotiation completion after active state is
        // gone. Treat it as stale instead: the negotiated data has no context
        // to commit into, so propagate the recoverable reconnect signal.
        const active = self.state.activeState() orelse return error.SessionStale;
        const context = active.context;
        log.writef(.info, "Negotiation succeeded, set key {d} as current", .{result.key});
        var reply = try result.push_reply.clone(self.session.allocator);
        var owns_reply = true;
        errdefer if (owns_reply) reply.deinit(self.session.allocator);
        log.writef(.info, "Replace key {d} with new data channel", .{
            result.data_channel.key,
        });
        try context.setDataChannel(result.data_channel, result.key);
        owns_data_channel = false;
        context.setPushReply(reply);
        owns_reply = false;
        if (self.session.auth_token) |token|
            try token.update(context.push_reply.?.options.auth_token);
        context.removeOldNegotiators();
        const negotiator_keys = context.negotiatorKeys();
        log.writef(.info, "Negotiators: {any}", .{negotiator_keys.slice()});
        const data_keys = context.dataKeys();
        log.writef(.info, "Data channels: {any}", .{data_keys.slice()});
        if (active.phase == .started) return;
        active.phase = .started;
        try self.scheduleNextPing(context);
        self.session.events.established(
            self.session.events.context,
            self.session,
            context.remote_endpoint,
            &context.push_reply.?.options,
        );
    }

    // MARK: Timers and keep-alive

    fn scheduleNegotiationCheck(
        self: *SessionOnQueue,
        delay_ms: u64,
    ) net.Looper.ScheduleTimerError!void {
        try self.session.looper.scheduleReplacing(
            &self.negotiation_timer,
            delay_ms,
            .{ .context = self, .callback = onNegotiationTimer },
        );
    }

    fn scheduleNextPing(
        self: *SessionOnQueue,
        context: *ActiveContext,
    ) !void {
        const delay_ms = self.keepAliveIntervalMs(context) orelse
            self.session.options.ping_timeout_check_interval_ms;
        log.logTimeMs(.debug, "Schedule ping check after ", delay_ms);
        try self.session.looper.scheduleReplacing(
            &self.ping_timer,
            delay_ms,
            .{ .context = self, .callback = onPingTimer },
        );
    }

    fn onNegotiationTimer(raw: ?*anyopaque) void {
        const self: *SessionOnQueue = @ptrCast(@alignCast(raw.?));
        self.checkNegotiation() catch |err| {
            self.session.reportFailure(err);
        };
    }

    fn checkNegotiation(self: *SessionOnQueue) !void {
        const active = self.state.activeState() orelse return;
        if (active.phase == .stopping) return;
        const context = active.context;
        const negotiator = context.currentNegotiator() orelse
            @panic("Active session negotiation timer fired without a negotiator");
        try negotiator.checkNegotiation();
    }

    fn onPingTimer(raw: ?*anyopaque) void {
        const self: *SessionOnQueue = @ptrCast(@alignCast(raw.?));
        self.ping() catch |err| {
            self.session.reportFailure(err);
        };
    }

    fn ping(self: *SessionOnQueue) !void {
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

    fn checkPingTimeout(self: *SessionOnQueue, context: *ActiveContext) !void {
        const last_received = context.last_received_ns orelse return;
        const deadline = core.concurrency.deadlineAfterMs(
            last_received,
            self.keepAliveTimeoutMs(context),
        );
        if (core.concurrency.monotonicNs() > deadline)
            return error.Timeout;
    }

    fn keepAliveIntervalMs(self: *SessionOnQueue, context: *ActiveContext) ?u64 {
        const pushed = if (context.push_reply) |reply|
            reply.options.keep_alive_interval
        else
            null;
        return keepAliveMs(pushed, self.session.configuration.keep_alive_interval);
    }

    fn keepAliveTimeoutMs(self: *SessionOnQueue, context: *ActiveContext) u64 {
        const pushed = if (context.push_reply) |reply|
            reply.options.keep_alive_timeout
        else
            null;
        return keepAliveMs(pushed, self.session.configuration.keep_alive_timeout) orelse
            self.session.options.ping_timeout_ms;
    }

    fn keepAliveMs(pushed: ?f64, configured: ?f64) ?u64 {
        for ([_]?f64{ pushed, configured }) |candidate| {
            const seconds = candidate orelse continue;
            if (seconds > 0) return core.util.secondsToMilliseconds(seconds);
        }
        return null;
    }

    // MARK: Data callbacks

    fn dataChannelForKey(self: *SessionOnQueue, key: u8) ?*DataChannel {
        const context = self.state.activeContext() orelse return null;
        return context.dataChannel(key);
    }

    fn reportInboundDataCount(self: *SessionOnQueue, count: usize) void {
        const context = self.state.activeContext() orelse return;
        self.addDataCount(context, &context.data_count.inbound, count);
    }

    fn reportOutboundDataCount(self: *SessionOnQueue, count: usize) void {
        const context = self.state.activeContext() orelse return;
        self.addDataCount(context, &context.data_count.outbound, count);
    }

    fn addDataCount(
        self: *SessionOnQueue,
        context: *ActiveContext,
        total: *u64,
        count: usize,
    ) void {
        total.* = std.math.add(u64, total.*, @intCast(count)) catch std.math.maxInt(u64);
        self.reportCurrentDataCount(context);
    }

    fn reportCurrentDataCount(self: *SessionOnQueue, context: *ActiveContext) void {
        const now = core.concurrency.monotonicNs();
        if (context.last_data_count_ns) |last| {
            const next = core.concurrency.deadlineAfterMs(
                last,
                self.session.options.min_data_count_interval_ms,
            );
            if (self.session.options.min_data_count_interval_ms > 0 and now < next) return;
        }
        context.last_data_count_ns = now;
        self.session.events.data_count(self.session.events.context, self.session, .{
            .received = context.data_count.inbound,
            .sent = context.data_count.outbound,
        });
    }
};

fn sideFailureError(failure: net.Looper.Failure, fallback: SessionError) SessionError {
    return switch (failure) {
        .user => |cause| @errorCast(cause),
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
