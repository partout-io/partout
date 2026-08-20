// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const control_mod = @import("control.zig");
const control_serializers_mod = @import("control_serializers.zig");
const crypto_mod = @import("crypto.zig");
const data_mod = @import("data.zig");
const errors_mod = @import("errors.zig");
const helpers_mod = @import("helpers.zig");
const packet_mod = @import("packet.zig");
const processing_mod = @import("processing.zig");
const push_mod = @import("push.zig");
const session_context_mod = @import("session_context.zig");
const session_negotiator_mod = @import("session_negotiator.zig");
const tls_mod = @import("tls.zig");

const session_mod = @This();
const api = core.api;
const c = helpers_mod.c;
const log = core.logging;

const ActiveContext = session_context_mod.ActiveContext;
const SessionOptions = configuration_mod.SessionOptions;
const ControlChannel = control_mod.ControlChannel(control_serializers_mod.Serializer);
const ControlConstants = constants_mod.Control;
const DataChannel = data_mod.DataChannel;
const DataLink = data_mod.DataLink;
const LinkProcessor = processing_mod.LinkProcessor;
const Negotiator = session_negotiator_mod.Negotiator;
const OCCPacket = packet_mod.OCCPacket;
const PacketCode = packet_mod.PacketCode;
const PRNG = crypto_mod.PRNG;
const PushReply = push_mod.PushReply;
const RenegotiationType = session_negotiator_mod.RenegotiationType;
const Serializer = control_serializers_mod.Serializer;
const SessionState = session_context_mod.SessionState;
const SessionError = errors_mod.SessionError;
const TLSWrapper = tls_mod.TLSWrapper;

/// Type-erased observer for major session events.
///
/// Values passed to callbacks are borrowed for the duration of the callback.
/// Callbacks execute on the session looper.
pub const SessionDelegate = struct {
    context: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        did_start: *const fn (
            ?*anyopaque,
            *anyopaque,
            api.ExtendedEndpoint,
            *const api.OpenVPNConfiguration,
        ) void,
        did_stop: *const fn (?*anyopaque, *anyopaque, ?SessionError) void,
        did_update_data_count: *const fn (
            ?*anyopaque,
            *anyopaque,
            api.DataCount,
        ) void,
    };

    pub fn didStart(
        self: SessionDelegate,
        session: *anyopaque,
        remote_endpoint: api.ExtendedEndpoint,
        remote_options: *const api.OpenVPNConfiguration,
    ) void {
        self.vtable.did_start(
            self.context,
            session,
            remote_endpoint,
            remote_options,
        );
    }

    pub fn didStop(
        self: SessionDelegate,
        session: *anyopaque,
        cause: ?SessionError,
    ) void {
        self.vtable.did_stop(self.context, session, cause);
    }

    pub fn didUpdateDataCount(
        self: SessionDelegate,
        session: *anyopaque,
        count: api.DataCount,
    ) void {
        self.vtable.did_update_data_count(self.context, session, count);
    }
};

/// Default V3 OpenVPN session implementation.
///
/// `Session` is heap-only: callbacks and timer contexts borrow this stable
/// address until `destroy` joins them. Its `Looper` is borrowed and dedicated
/// to this session for the same lifetime.
pub const Session = struct {
    pub const Error = errors_mod.SessionError;

    allocator: std.mem.Allocator,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    prng: PRNG,
    caches_directory: []u8,
    ca_filename: []u8,
    options: SessionOptions,

    executor: net.SerializedExecutor,
    looper: *net.Looper,
    control_channel: *ControlChannel,
    on_queue: SessionOnQueue,
    lifecycle_lock: core.Mutex = .{},
    negotiation_timer: core.RunAfter = .{},
    ping_timer: core.RunAfter = .{},

    delegate: ?SessionDelegate = null,
    state: SessionState = .{ .stopped = .{ .with_local_options = true } },
    link_processor: ?*LinkProcessor = null,

    shutdown_state: ShutdownState = .{},

    pub const Init = struct {
        executor: net.SerializedExecutor,
        looper: *net.Looper,
        configuration: api.OpenVPNConfiguration,
        credentials: ?api.OpenVPNCredentials,
        prng: PRNG,
        caches_directory: []const u8,
        ca_filename: []const u8,
        options: SessionOptions,
    };

    // MARK: - Public API

    pub fn create(allocator: std.mem.Allocator, init: Init) Error!*Session {
        return createFallible(allocator, init) catch |err| errors_mod.sessionError(err);
    }

    /// Must run outside every looper, timer, and delegate callback while the
    /// borrowed looper remains alive and running. This does not stop or
    /// deinitialize the looper.
    pub fn destroy(self: *Session) void {
        if (self.looper.isOnQueue())
            @panic("Session.destroy() must run outside looper callbacks");

        log.write(.debug, "Deinit OpenVPNSession");
        self.negotiation_timer.cancel();
        self.ping_timer.cancel();

        self.shutdown(null, 0) catch {};
        self.negotiation_timer.deinit();
        self.ping_timer.deinit();

        switch (self.state) {
            .stopped => {},
            .active => |active| active.context.destroy(),
        }
        if (self.link_processor) |processor| processor.destroy();
        self.control_channel.destroy();
        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.caches_directory);
        self.allocator.free(self.ca_filename);
        self.shutdown_state.deinit();
        self.lifecycle_lock.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn setDelegate(self: *Session, delegate: ?SessionDelegate) void {
        if (self.looper.isOnQueue()) {
            self.onQueue().setDelegate(delegate);
            return;
        }
        _ = self.performOnQueue(void, delegate, SessionOnQueue.setDelegate) catch {};
    }

    pub fn setLink(
        self: *Session,
        descriptor: net.Looper.Descriptor,
        remote_endpoint: api.ExtendedEndpoint,
    ) Error!void {
        var descriptor_transferred = false;
        defer if (!descriptor_transferred) descriptor.io.cleanup();

        if (self.looper.isOnQueue()) return errors_mod.sessionError(error.ReentrantCall);
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        if (self.looper.isLinkAttached()) {
            log.write(.err, "Link interface already set");
            return;
        }

        const processor = LinkProcessor.create(
            self.allocator,
            self.configuration.xor_method,
            remote_endpoint.plainSocketType() == .tcp,
        ) catch |err| return errors_mod.sessionError(err);
        self.link_processor = processor;
        errdefer {
            if (self.link_processor == processor) {
                self.link_processor = null;
                processor.destroy();
            }
        }

        log.write(.info, "Attach LINK");
        self.looper.attach(.{
            .pair = .{ .link = descriptor },
            .on_read = .{ .context = self, .callback = onLinkRead },
            .on_failure = .{ .context = self, .callback = onLinkFailure },
        }) catch |err| return errors_mod.sessionError(err);
        descriptor_transferred = true;
        errdefer self.looper.detach(.link) catch {};
        self.performOnQueue(void, remote_endpoint, SessionOnQueue.setLink) catch |err|
            return errors_mod.sessionError(err);
    }

    pub fn setTunnel(self: *Session, descriptor: net.Looper.Descriptor) Error!void {
        var descriptor_transferred = false;
        defer if (!descriptor_transferred) descriptor.io.cleanup();

        if (self.looper.isOnQueue()) return errors_mod.sessionError(error.ReentrantCall);
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        if (!self.looper.isLinkAttached()) {
            log.write(.err, "Set link interface first");
            return;
        }
        if (self.looper.isTunAttached()) {
            log.write(.err, "Tunnel interface already set");
            return;
        }
        log.write(.info, "Attach TUN");
        self.looper.attach(.{
            .pair = .{ .tun = descriptor },
            .on_read = .{ .context = self, .callback = onTunnelRead },
            .on_failure = .{ .context = self, .callback = onSideFailure },
        }) catch |err| return errors_mod.sessionError(err);
        descriptor_transferred = true;
    }

    /// Prepares state on the looper, detaches from this external thread, then
    /// finishes state on the looper.
    pub fn shutdown(
        self: *Session,
        cause: ?SessionError,
        timeout_ms: ?u64,
    ) Error!void {
        if (!self.shutdown_state.claim()) return;
        if (self.looper.isOnQueue()) return errors_mod.sessionError(error.ReentrantCall);
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        const request = ShutdownRequest{
            .cause = cause,
            .timeout_ms = timeout_ms,
        };
        const should_detach = self.performOnQueue(
            bool,
            request,
            SessionOnQueue.prepareShutdown,
        ) catch |err| {
            // Swift owns its looper and logs any perform failure here. Zig's
            // looper is externally owned: LooperUnavailable means OnFinish
            // through looperDidTerminate owns finalization, so do not shut down
            // twice.
            if (err == error.LooperUnavailable) return;
            log.writef(.err, "Unable to shut down session on looper queue: {s}", .{
                @errorName(err),
            });
            return errors_mod.sessionError(err);
        };
        if (!should_detach) return;
        // Detach is best-effort, matching Swift's nonthrowing detach calls.
        // State must still leave `.stopping` if a side failed independently.
        if (self.looper.isTunAttached()) self.looper.detach(.tun) catch {};
        if (self.looper.isLinkAttached()) self.looper.detach(.link) catch {};
        self.performOnQueue(void, cause, SessionOnQueue.finishShutdown) catch |err|
            return errors_mod.sessionError(err);
    }

    /// Routes the externally owned looper's terminal callback into the
    /// session. The owner must call this synchronously from `Looper.OnFinish`
    /// while the Session is alive, and must stop forwarding before `destroy`.
    pub fn looperDidTerminate(self: *Session, failure: ?net.Looper.Failure) void {
        _ = self.shutdown_state.claim();
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
        self.onQueue().finishShutdown(
            if (failure) |value| failureError(value) else null,
        );
    }

    // MARK: - Private construction

    fn createFallible(allocator: std.mem.Allocator, init: Init) !*Session {
        var owned_configuration = try init.configuration.clone(allocator);
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
        const serializer = try Serializer.forConfiguration(
            allocator,
            init.options.backend,
            &owned_configuration,
        );
        const control_channel = try ControlChannel.create(allocator, init.prng, serializer);
        errdefer control_channel.destroy();

        const self = try allocator.create(Session);
        self.* = .{
            .allocator = allocator,
            .configuration = owned_configuration,
            .credentials = owned_credentials,
            .prng = init.prng,
            .caches_directory = owned_caches_directory,
            .ca_filename = owned_ca_filename,
            .options = init.options,
            .executor = init.executor,
            .looper = init.looper,
            .control_channel = control_channel,
            .on_queue = SessionOnQueue.init(self),
        };
        return self;
    }

    // MARK: - From any thread

    fn requestShutdownFromAnyThread(self: *Session, cause: SessionError) void {
        if (!self.shutdown_state.enqueue(.{
            .cause = cause,
            .timeout_ms = null,
        })) return;
        self.executor.run(self, shutdownFromAnyThread);
    }

    fn shutdownFromAnyThread(raw: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        const request = self.shutdown_state.takeRequest() orelse return;
        self.shutdown(request.cause, request.timeout_ms) catch |err| {
            log.writef(.err, "Unable to shut down session on looper queue: {s}", .{
                @errorName(err),
            });
        };
    }

    // MARK: - Callback boundaries

    fn onSideFailure(raw: ?*anyopaque, failure: net.Looper.Failure) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdownFromAnyThread(failureError(failure));
    }

    fn onLinkFailure(raw: ?*anyopaque, failure: net.Looper.Failure) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const cause = failureError(failure);
        self.requestShutdownFromAnyThread(
            // Swift wraps every link failure as an I/O failure, making even a
            // crypto/data-path cause recoverable; tunnel failures stay unchanged.
            // Preserve that link-only behavior with Zig's reconnect signal.
            if (cause == error.CryptoFailure) error.Reconnect else cause,
        );
    }

    fn onLinkRead(
        raw: ?*anyopaque,
        packets: net.Looper.Packets,
    ) !net.Looper.ReadAction {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const processor = self.link_processor orelse return .keep;
        var processed = try processor.processInbound(packets);
        defer processed.deinit();
        try self.onQueue().receiveLink(processed.packets());
        return .keep;
    }

    fn onTunnelRead(
        raw: ?*anyopaque,
        packets: net.Looper.Packets,
    ) !net.Looper.ReadAction {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.onQueue().receiveTunnel(packets);
        return .keep;
    }

    fn didNegotiate(
        raw: ?*anyopaque,
        key: u8,
        data_channel: *DataChannel,
        push_reply: *const PushReply,
    ) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.onQueue().didNegotiate(key, data_channel, push_reply);
    }

    fn onNegotiatorError(raw: ?*anyopaque, _: u8, cause: SessionError) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdownFromAnyThread(cause);
    }

    fn onTLSVerificationFailure(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdownFromAnyThread(error.TLSFailure);
    }

    fn onNegotiationTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.dispatchTimerTask(negotiationTick);
    }

    fn negotiationTick(raw: ?*anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.onQueue().negotiationTick();
    }

    fn onPingTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.dispatchTimerTask(ping);
    }

    fn ping(raw: ?*anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.onQueue().ping();
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

    fn dispatchTimerTask(
        self: *Session,
        callback: *const fn (?*anyopaque) anyerror!void,
    ) void {
        self.looper.performTask(.{
            .context = self,
            .callback = callback,
        }) catch |err| {
            // Swift lets its timer task feed perform failure back into shutdown.
            // Here LooperUnavailable means looperDidTerminate already owns
            // finalization, so another shutdown request would be redundant.
            if (err != error.LooperUnavailable)
                self.requestShutdownFromAnyThread(errors_mod.sessionError(err));
        };
    }

    fn failureError(failure: net.Looper.Failure) SessionError {
        return switch (failure) {
            .user, .system => |cause| errors_mod.sessionError(cause),
            .io => |details| errors_mod.sessionError(details.cause),
            .wait => |code| {
                log.writef(.err, "OpenVPN looper wait failed with native code: {}", .{code});
                // Swift's private WaitError becomes a recoverable OpenVPN
                // connection failure. Zig cannot carry its native code in an
                // error value, so log it above and preserve the reconnect choice.
                return error.Reconnect;
            },
        };
    }

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
        return self.looper.perform(Result, &request, Request.run);
    }

    fn onQueue(self: *Session) *SessionOnQueue {
        std.debug.assert(self.looper.isOnQueue());
        return &self.on_queue;
    }

    const ShutdownRequest = struct {
        cause: ?SessionError,
        timeout_ms: ?u64,
    };

    const ShutdownState = struct {
        lock: core.Mutex = .{},
        claimed: bool = false,
        requested: ?ShutdownRequest = null,

        fn deinit(self: *ShutdownState) void {
            self.lock.deinit();
        }

        fn enqueue(self: *ShutdownState, request: ShutdownRequest) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.claimed or self.requested != null) return false;
            self.requested = request;
            return true;
        }

        fn takeRequest(self: *ShutdownState) ?ShutdownRequest {
            self.lock.lock();
            defer self.lock.unlock();
            const request = self.requested;
            self.requested = null;
            return request;
        }

        fn claim(self: *ShutdownState) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.claimed) return false;
            self.claimed = true;
            return true;
        }
    };
};

// MARK: - On queue

/// A serialized view created once with its stable parent pointer and embedded
/// in `Session`. Methods below never acquire Session locks, and external
/// callbacks re-enter through `Session.onQueue`.
const SessionOnQueue = struct {
    session: *Session,

    fn init(session: *Session) SessionOnQueue {
        return .{ .session = session };
    }

    fn setDelegate(self: *SessionOnQueue, delegate: ?SessionDelegate) void {
        self.session.delegate = delegate;
    }

    // MARK: Lifecycle

    fn setLink(self: *SessionOnQueue, remote_endpoint: api.ExtendedEndpoint) !void {
        const idle = switch (self.session.state) {
            .stopped => |context| context,
            .active => {
                log.write(.err, "Session is not stopped");
                // Swift calls this operationCancelled. Name the concrete Zig
                // state instead: this is not an in-place restart.
                return error.SessionAlreadyActive;
            },
        };
        log.write(.info, "Start VPN session");
        const processor = self.session.link_processor orelse
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
        self.session.state = .{ .active = .{
            .phase = .starting,
            .context = active_context,
        } };
        self.startNegotiation() catch |err| {
            active_context.destroy();
            self.session.state = .{ .stopped = idle };
            return err;
        };
    }

    fn prepareShutdown(self: *SessionOnQueue, request: Session.ShutdownRequest) bool {
        const active = self.session.state.activeState() orelse {
            log.write(.debug, "Ignore stop request, stopped or already stopping");
            return false;
        };
        if (active.phase == .stopping) {
            log.write(.debug, "Ignore stop request, stopped or already stopping");
            return false;
        }
        if (request.cause) |cause| {
            log.writef(.err, "Shut down with failure: {s}", .{@errorName(cause)});
        } else {
            log.write(.info, "Shut down on request");
        }
        active.phase = .stopping;
        self.session.negotiation_timer.cancel();
        self.session.ping_timer.cancel();

        if (shouldSendExitNotification(request.cause)) self.sendExitPacket(
            request.timeout_ms orelse self.session.options.write_timeout_ms,
        ) catch |err| {
            log.writef(.err, "Unable to send exit packet: {s}", .{@errorName(err)});
        };
        return true;
    }

    fn finishShutdown(self: *SessionOnQueue, cause: ?SessionError) void {
        const active = switch (self.session.state) {
            .stopped => return,
            .active => |value| value,
        };
        // Terminal looper failures bypass prepareShutdown(), so cancel
        // both Session-owned replacements for the Swift context's Tasks here
        // as well as in the normal shutdown path.
        self.session.negotiation_timer.cancel();
        self.session.ping_timer.cancel();
        const next_with_local_options = if (cause) |value|
            active.context.with_local_options and value != error.BadCredentialsWithLocalOptions
        else
            active.context.with_local_options;
        active.context.destroy();
        self.session.state = .{ .stopped = .{
            .with_local_options = next_with_local_options,
        } };
        if (self.session.link_processor) |processor| processor.destroy();
        self.session.link_processor = null;
        if (self.session.delegate) |delegate| delegate.didStop(self.session, cause);
    }

    fn sendExitPacket(self: *SessionOnQueue, timeout_ms: u64) !void {
        const context = self.session.state.activeContext() orelse return;
        if (context.remote_endpoint.plainSocketType() != .udp) return;
        const pair = context.current_data_pair orelse return;
        log.write(.info, "Send OCCPacket exit");
        const exit = OCCPacket.exit.serialized();
        const packet: []const u8 = &exit;
        try pair.send(&.{packet}, null, timeout_ms);
        log.write(.info, "Sent OCCPacket correctly");
    }

    // MARK: Packet I/O

    fn receiveLink(self: *SessionOnQueue, packets: []const []const u8) !void {
        const context = self.session.state.activeContext() orelse return;
        context.last_received_ns = core.concurrency.monotonicNs();
        var negotiator = context.currentNegotiator() orelse {
            @panic("Active session received link packets without a negotiator");
        };
        if (negotiator.shouldRenegotiate())
            negotiator = try self.startRenegotiation(negotiator, .client);

        var grouped = [_]std.ArrayList([]const u8){.empty} **
            ControlConstants.number_of_keys;
        defer for (&grouped) |*list| list.deinit(self.session.allocator);
        for (packets) |packet| {
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
            if (code == .dataV2 and packet.len <= c.OpenVPNPacketPeerIdLength) {
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
            var parsed = self.session.control_channel.readInboundPacket(packet, 0) catch |err| {
                log.writef(.err, "Dropped malformed packet: {s}", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();
            if (parsed.code == .ackV1) continue;
            switch (code) {
                .hardResetServerV2 => {
                    if (negotiator.isConnected()) {
                        log.write(.notice, "OpenVPN server requested a fresh session; reconnecting");
                        // Swift reports recoverable(staleSession) here. Zig
                        // collapses that wrapper to Reconnect: a connected session
                        // cannot accept a fresh server session ID in place.
                        return error.Reconnect;
                    }
                },
                .softResetV1 => {
                    negotiator = try self.startRenegotiation(negotiator, .server);
                },
                else => {},
            }
            negotiator.sendAck(&parsed);
            const inbound = try self.session.control_channel.enqueueInboundPacket(parsed.move());
            defer {
                for (inbound) |*owned| owned.deinit();
                self.session.allocator.free(inbound);
            }
            for (inbound) |*owned| {
                log.writef(.debug, "Handle packet: {d}", .{owned.packetId()});
                try negotiator.handleControlPacket(owned);
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

    fn receiveTunnel(self: *SessionOnQueue, packets: []const []const u8) !void {
        const context = self.session.state.activeContext() orelse return;
        const pair = context.current_data_pair orelse return;
        try self.checkPingTimeout(context);
        try pair.send(packets, null, null);
    }

    // MARK: Negotiation

    fn startNegotiation(self: *SessionOnQueue) !void {
        log.write(.info, "Start negotiation");
        const context = self.session.state.activeContext() orelse
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
            .link_processor = self.session.link_processor orelse
                @panic("Cannot start negotiation before the link processor is configured"),
            .remote_endpoint = &context.remote_endpoint,
            .channel = self.session.control_channel,
            .prng = self.session.prng,
            .tls = tls,
            .options = .{
                .configuration = &self.session.configuration,
                .credentials = if (self.session.credentials) |*value| value else null,
                .with_local_options = context.with_local_options,
                .session_options = self.session.options,
                .callback_context = self.session,
                .on_connected = Session.didNegotiate,
                .on_error = Session.onNegotiatorError,
            },
        });
        tls_transferred = true;
        context.addNegotiator(negotiator);
        try negotiator.start();
        try self.scheduleNegotiationTick();
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
        const context = self.session.state.activeContext() orelse
            @panic("Cannot start renegotiation while the session is stopped");
        const negotiator = try previous.forRenegotiation(initiated_by);
        context.addNegotiator(negotiator);
        try negotiator.start();
        try self.scheduleNegotiationTick();
        return negotiator;
    }

    fn didNegotiate(
        self: *SessionOnQueue,
        key: u8,
        data_channel: *DataChannel,
        push_reply: *const PushReply,
    ) !void {
        // Swift silently drops a negotiation completion after active state is
        // gone. Treat it as stale instead: the negotiated data has no context
        // to commit into, so propagate the recoverable reconnect signal.
        const active = self.session.state.activeState() orelse return error.Reconnect;
        const context = active.context;
        log.writef(.info, "Negotiation succeeded, set key {d} as current", .{key});
        var reply = push_reply.clone(self.session.allocator) catch |err|
            return errors_mod.sessionError(err);
        errdefer reply.deinit(self.session.allocator);
        log.writef(.info, "Replace key {d} with new data channel", .{
            data_channel.key,
        });
        context.setDataChannel(data_channel, key) catch |err|
            return errors_mod.sessionError(err);
        context.setPushReply(reply);
        context.removeOldNegotiators();
        const negotiator_keys = context.negotiatorKeys();
        log.writef(.info, "Negotiators: {any}", .{negotiator_keys.slice()});
        const data_keys = context.dataKeys();
        log.writef(.info, "Data channels: {any}", .{data_keys.slice()});
        if (active.phase == .started) return;
        active.phase = .started;
        self.scheduleNextPing(context) catch |err|
            return errors_mod.sessionError(err);
        if (self.session.delegate) |delegate| delegate.didStart(
            self.session,
            context.remote_endpoint,
            &context.push_reply.?.options,
        );
    }

    // MARK: Timers and keep-alive

    fn scheduleNegotiationTick(self: *SessionOnQueue) !void {
        try self.session.negotiation_timer.scheduleReplacing(
            self.session.options.tick_interval_ms,
            Session.onNegotiationTimer,
            self.session,
        );
    }

    fn negotiationTick(self: *SessionOnQueue) !void {
        const context = self.session.state.activeContext() orelse return;
        const negotiator = context.currentNegotiator() orelse
            @panic("Active session negotiation timer fired without a negotiator");
        if (try negotiator.tick()) try self.scheduleNegotiationTick();
    }

    fn scheduleNextPing(self: *SessionOnQueue, context: *ActiveContext) !void {
        const delay = self.keepAliveIntervalMs(context) orelse
            self.session.options.ping_timeout_check_interval_ms;
        log.logTimeMs(.debug, "Schedule ping check after ", delay);
        try self.session.ping_timer.scheduleReplacing(delay, Session.onPingTimer, self.session);
    }

    fn ping(self: *SessionOnQueue) !void {
        const context = self.session.state.activeContext() orelse {
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
        return keepAliveMilliseconds(pushed, self.session.configuration.keep_alive_interval);
    }

    fn keepAliveTimeoutMs(self: *SessionOnQueue, context: *ActiveContext) u64 {
        const pushed = if (context.push_reply) |reply|
            reply.options.keep_alive_timeout
        else
            null;
        return keepAliveMilliseconds(pushed, self.session.configuration.keep_alive_timeout) orelse
            self.session.options.ping_timeout_ms;
    }

    fn keepAliveMilliseconds(pushed: ?f64, configured: ?f64) ?u64 {
        for ([_]?f64{ pushed, configured }) |candidate| {
            const seconds = candidate orelse continue;
            if (seconds > 0) return core.util.secondsToMilliseconds(seconds);
        }
        return null;
    }

    // MARK: Data callbacks

    fn dataChannelForKey(self: *SessionOnQueue, key: u8) ?*DataChannel {
        const context = self.session.state.activeContext() orelse return null;
        return context.dataChannel(key);
    }

    fn reportInboundDataCount(self: *SessionOnQueue, count: usize) void {
        const context = self.session.state.activeContext() orelse return;
        self.addDataCount(context, &context.data_count.inbound, count);
    }

    fn reportOutboundDataCount(self: *SessionOnQueue, count: usize) void {
        const context = self.session.state.activeContext() orelse return;
        self.addDataCount(context, &context.data_count.outbound, count);
    }

    fn addDataCount(
        self: *SessionOnQueue,
        context: *ActiveContext,
        total: *u64,
        count: usize,
    ) void {
        total.* = std.math.add(u64, total.*, @intCast(count)) catch std.math.maxInt(u64);
        self.delegateCurrentDataCount(context);
    }

    fn delegateCurrentDataCount(self: *SessionOnQueue, context: *ActiveContext) void {
        const now = core.concurrency.monotonicNs();
        if (context.last_data_count_ns) |last| {
            const next = core.concurrency.deadlineAfterMs(
                last,
                self.session.options.min_data_count_interval_ms,
            );
            if (self.session.options.min_data_count_interval_ms > 0 and now < next) return;
        }
        context.last_data_count_ns = now;
        if (self.session.delegate) |delegate| delegate.didUpdateDataCount(self.session, .{
            .received = context.data_count.inbound,
            .sent = context.data_count.outbound,
        });
    }
};

fn shouldSendExitNotification(cause: ?SessionError) bool {
    // Mirror Swift's `error == nil || error == networkChanged` choice: notify
    // only for an orderly stop or path change; other failures tear down at once.
    return if (cause) |value| value == error.NetworkChanged else true;
}

pub const testing = struct {
    pub const shouldSendExitNotification = session_mod.shouldSendExitNotification;
};
