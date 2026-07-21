// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const ActiveContext = @import("active_context.zig").ActiveContext;
const ActivePhase = @import("active_phase.zig").ActivePhase;
const c = @import("c.zig").api;
const CPacketCode = @import("c_packet_code.zig").CPacketCode;
const ConnectionOptions = @import("connection_options.zig").ConnectionOptions;
const ControlChannelConstants = @import("control_channel_constants.zig").ControlChannel;
const ControlChannelV3 = @import("control_channel_v3.zig").ControlChannelV3;
const credentials_helpers = @import("credentials_helpers.zig");
const DataChannel = @import("data_channel.zig").DataChannel;
const DataLink = @import("data_link.zig").DataLink;
const DataPathFactory = @import("factories.zig").DataPathFactory;
const errors = @import("errors.zig");
const IdleContext = @import("idle_context.zig").IdleContext;
const LinkProcessor = @import("link_processor.zig").LinkProcessor;
const NegotiatorOptions = @import("negotiator_options.zig").NegotiatorOptions;
const NegotiatorV3 = @import("negotiator_v3.zig").NegotiatorV3;
const OCCPacket = @import("occ_packet.zig").OCCPacket;
const PRNG = @import("prng.zig").PRNG;
const PushReply = @import("push_reply.zig").PushReply;
const RenegotiationType = @import("renegotiation_type.zig").RenegotiationType;
const SessionDelegate = @import("session_delegate.zig").SessionDelegate;
const SessionProtocol = @import("session_protocol.zig").SessionProtocol;
const SessionState = @import("session_state.zig").SessionState;
const TLSFactory = @import("factories.zig").TLSFactory;
const TLSParameters = @import("tls_parameters.zig").TLSParameters;

const api = core.api;

/// Default V3 OpenVPN session implementation.
///
/// `Session` is heap-only: looper callbacks, the shutdown actor, and timer
/// contexts all borrow this stable address until `destroy` joins them. The
/// `Looper` itself is borrowed; its owner initializes and starts it, keeps it
/// alive and running through `destroy`, then stops and deinitializes it.
/// It is dedicated to this Session while borrowed because Session manages its
/// single link/tunnel pair.
/// Public lifecycle methods are synchronous because `Looper` already
/// serializes and waits for attach/perform/detach completion. The external
/// owner must not retain a direct Session callback after `destroy` returns.
pub const Session = struct {
    allocator: std.mem.Allocator,
    fnt: c.pp_crypto_fnt,
    configuration: api.OpenVPNConfiguration,
    credentials: ?api.OpenVPNCredentials,
    prng: PRNG,
    caches_directory: []u8,
    options: ConnectionOptions,
    tls_factory: TLSFactory,
    data_path_factory: DataPathFactory,

    looper: *net.Looper,
    control_channel: *ControlChannelV3,
    shutdown_actor: ?*ShutdownActor,
    lifecycle_lock: core.Mutex = .{},
    negotiation_timer: core.RunAfter = .{},
    ping_timer: core.RunAfter = .{},

    delegate: ?SessionDelegate = null,
    state: SessionState = .{ .stopped = .{ .with_local_options = true } },
    link_processor: ?*LinkProcessor = null,

    const ShutdownRequest = struct {
        cause: ?anyerror,
        timeout_ms: ?u64 = null,
    };

    const ShutdownActor = core.Actor(
        Session,
        ShutdownRequest,
        anyerror,
        handleShutdownRequest,
    );

    pub fn create(
        allocator: std.mem.Allocator,
        looper: *net.Looper,
        fnt: c.pp_crypto_fnt,
        configuration: api.OpenVPNConfiguration,
        credentials: ?api.OpenVPNCredentials,
        prng: PRNG,
        caches_directory: []const u8,
        options: ConnectionOptions,
        tls_factory: TLSFactory,
        data_path_factory: DataPathFactory,
    ) anyerror!*Session {
        var owned_configuration = try configuration.clone(allocator);
        errdefer owned_configuration.deinit(allocator);
        var owned_credentials = if (credentials) |value|
            try credentials_helpers.forAuthentication(allocator, value)
        else
            null;
        errdefer if (owned_credentials) |*value| value.deinit(allocator);
        const owned_caches_directory = try allocator.dupe(u8, caches_directory);
        errdefer allocator.free(owned_caches_directory);
        const control_channel = try ControlChannelV3.createForConfiguration(
            allocator,
            fnt.enc,
            prng,
            &owned_configuration,
        );
        errdefer control_channel.destroy();

        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .fnt = fnt,
            .configuration = owned_configuration,
            .credentials = owned_credentials,
            .prng = prng,
            .caches_directory = owned_caches_directory,
            .options = options,
            .tls_factory = tls_factory,
            .data_path_factory = data_path_factory,
            .looper = looper,
            .control_channel = control_channel,
            .shutdown_actor = null,
        };
        errdefer self.lifecycle_lock.deinit();
        self.shutdown_actor = try ShutdownActor.create(allocator, self);
        errdefer {
            self.shutdown_actor.?.deinit();
            self.shutdown_actor = null;
        }
        return self;
    }

    /// Must run outside every looper, timer, and delegate callback while the
    /// borrowed looper remains alive and running. This does not stop or
    /// deinitialize the looper.
    pub fn destroy(self: *Session) void {
        if (self.looper.isOnQueue())
            @panic("Session.destroy() must run outside looper callbacks");

        self.negotiation_timer.cancel();
        self.ping_timer.cancel();

        // Keep timer synchronization and the shutdown actor alive while the
        // regular lifecycle path finishes: prepare/finish both cancel timers,
        // and an already-running timer callback may still queue shutdown.
        self.shutdown(null, 0) catch {};
        self.negotiation_timer.deinit();
        self.ping_timer.deinit();

        if (self.shutdown_actor) |actor| {
            self.shutdown_actor = null;
            actor.deinit();
        }
        switch (self.state) {
            .stopped => {},
            .active => |active| active.context.destroy(),
        }
        if (self.link_processor) |processor| processor.destroy();
        self.link_processor = null;
        self.control_channel.destroy();
        self.configuration.deinit(self.allocator);
        if (self.credentials) |*credentials| credentials.deinit(self.allocator);
        self.allocator.free(self.caches_directory);
        self.lifecycle_lock.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn protocol(self: *Session) SessionProtocol {
        return .{ .ptr = self, .vtable = &protocol_vtable };
    }

    pub fn setDelegate(self: *Session, delegate: ?SessionDelegate) void {
        if (self.looper.isOnQueue()) {
            self.delegate = delegate;
            return;
        }
        var request = SetDelegateRequest{ .session = self, .delegate = delegate };
        _ = self.looper.perform(void, &request, setDelegateOnQueue) catch {};
    }

    pub fn setLink(
        self: *Session,
        descriptor: net.Looper.Descriptor,
        remote_endpoint: api.ExtendedEndpoint,
    ) anyerror!void {
        if (self.looper.isOnQueue()) return error.ReentrantCall;
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        if (self.looper.isLinkAttached()) return;

        const processor = try LinkProcessor.create(
            self.allocator,
            self.configuration.xor_method,
            remote_endpoint.plainSocketType() == .tcp,
        );
        self.link_processor = processor;
        var attached = false;
        errdefer {
            if (attached) self.looper.detach(.link) catch {};
            if (self.link_processor == processor) {
                self.link_processor = null;
                processor.destroy();
            }
        }

        try self.looper.attach(.{
            .pair = .{ .link = descriptor },
            .on_read = .{ .context = self, .callback = onLinkRead },
            .on_failure = .{ .context = self, .callback = onSideFailure },
        });
        attached = true;
        var request = SetLinkRequest{
            .session = self,
            .remote_endpoint = remote_endpoint,
        };
        try self.looper.perform(void, &request, setLinkOnQueue);
    }

    pub fn hasLink(self: *Session) bool {
        return self.looper.isLinkAttached();
    }

    pub fn setTunnel(self: *Session, descriptor: net.Looper.Descriptor) anyerror!void {
        if (self.looper.isOnQueue()) return error.ReentrantCall;
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        if (!self.looper.isLinkAttached() or self.looper.isTunAttached()) return;
        try self.looper.attach(.{
            .pair = .{ .tun = descriptor },
            .on_read = .{ .context = self, .callback = onTunnelRead },
            .on_failure = .{ .context = self, .callback = onSideFailure },
        });
    }

    /// Prepares state on the looper, detaches from this external thread, then
    /// finishes state on the looper. Calling it from a callback is rejected;
    /// callback failures go through `ShutdownActor` instead.
    pub fn shutdown(
        self: *Session,
        cause: ?anyerror,
        timeout_ms: ?u64,
    ) anyerror!void {
        if (self.looper.isOnQueue()) return error.ReentrantCall;
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        var prepare = ShutdownOnQueueRequest{
            .session = self,
            .cause = cause,
            .timeout_ms = timeout_ms,
        };
        const should_detach = self.looper.perform(
            bool,
            &prepare,
            prepareShutdownOnQueue,
        ) catch |err| {
            // A terminal looper has already serialized final state; its owner
            // routes `OnFinish` through `looperDidFinish` while Session lives.
            if (err == error.Cancelled or err == error.TerminalFailure) return;
            return err;
        };
        if (!should_detach) return;
        // Detach is best-effort, matching Swift's nonthrowing detach calls.
        // State must still leave `.stopping` if a side failed independently.
        if (self.looper.isTunAttached()) self.looper.detach(.tun) catch {};
        if (self.looper.isLinkAttached()) self.looper.detach(.link) catch {};
        var finish = FinishShutdownRequest{ .session = self, .cause = cause };
        try self.looper.perform(void, &finish, finishShutdownOnQueue);
    }

    fn requestShutdown(self: *Session, cause: ?anyerror) void {
        const actor = self.shutdown_actor orelse return;
        actor.schedule(.{ .cause = cause }) catch {};
    }

    fn handleShutdownRequest(
        self: *Session,
        request: ShutdownRequest,
    ) anyerror!void {
        try self.shutdown(request.cause, request.timeout_ms);
    }

    fn setLinkOnQueue(raw: ?*anyopaque) anyerror!void {
        const request: *SetLinkRequest = @ptrCast(@alignCast(raw.?));
        const self = request.session;
        std.debug.assert(self.looper.isOnQueue());
        const idle = switch (self.state) {
            .stopped => |context| context,
            .active => return error.OperationCancelled,
        };
        const processor = self.link_processor orelse return error.Assertion;
        const data_link = DataLink.init(
            self.allocator,
            self.looper,
            processor,
            self,
            .{
                .data_channel = dataChannelForKey,
                .report_inbound_data_count = reportInboundDataCount,
                .report_outbound_data_count = reportOutboundDataCount,
            },
        );
        const active_context = try ActiveContext.create(
            self.allocator,
            data_link,
            idle.with_local_options,
            request.remote_endpoint,
        );
        self.state = .{ .active = .{
            .phase = .starting,
            .context = active_context,
        } };
        _ = self.startNegotiationOnQueue() catch |err| {
            active_context.destroy();
            self.state = .{ .stopped = idle };
            return err;
        };
    }

    fn prepareShutdownOnQueue(raw: ?*anyopaque) anyerror!bool {
        const request: *ShutdownOnQueueRequest = @ptrCast(@alignCast(raw.?));
        const self = request.session;
        std.debug.assert(self.looper.isOnQueue());
        const active = self.state.activeState() orelse return false;
        if (active.phase == .stopping) return false;
        active.phase = .stopping;
        self.negotiation_timer.cancel();
        self.ping_timer.cancel();

        const should_notify = request.cause == null or
            request.cause.? == error.NetworkChanged or
            errors.partoutCode(request.cause.?) == .networkChanged;
        if (should_notify) self.sendExitPacketOnQueue(
            request.timeout_ms orelse self.options.write_timeout_ms,
        ) catch {};
        return true;
    }

    fn finishShutdownOnQueue(raw: ?*anyopaque) anyerror!void {
        const request: *FinishShutdownRequest = @ptrCast(@alignCast(raw.?));
        request.session.finishShutdown(request.cause);
    }

    fn finishShutdown(self: *Session, cause: ?anyerror) void {
        std.debug.assert(self.looper.isOnQueue());
        const active = switch (self.state) {
            .stopped => return,
            .active => |value| value,
        };
        // Terminal looper failures bypass prepareShutdownOnQueue(), so cancel
        // both Session-owned replacements for the Swift context's Tasks here
        // as well as in the normal shutdown path.
        self.negotiation_timer.cancel();
        self.ping_timer.cancel();
        const retries_without_local_options = if (cause) |value|
            value == error.BadCredentialsWithLocalOptions
        else
            false;
        const next_with_local_options = if (retries_without_local_options)
            false
        else
            active.context.with_local_options;
        active.context.destroy();
        self.state = .{ .stopped = .{
            .with_local_options = next_with_local_options,
        } };
        if (self.link_processor) |processor| processor.destroy();
        self.link_processor = null;
        if (self.delegate) |delegate| delegate.didStop(self, cause);
    }

    /// Routes the externally owned looper's terminal callback into the
    /// session. The owner must call this synchronously from `Looper.OnFinish`
    /// while the Session is alive, and must stop forwarding before `destroy`.
    pub fn looperDidFinish(self: *Session, failure: ?net.Looper.Failure) void {
        std.debug.assert(self.looper.isOnQueue());
        self.finishShutdown(if (failure) |value| failureError(value) else null);
    }

    fn onSideFailure(raw: ?*anyopaque, failure: net.Looper.Failure) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdown(failureError(failure));
    }

    fn onLinkRead(
        raw: ?*anyopaque,
        packets: net.Looper.Packets,
    ) anyerror!net.Looper.ReadAction {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const processor = self.link_processor orelse return .keep;
        var processed = try processor.processInbound(packets);
        defer processed.deinit();
        try self.receiveLink(processed.packets());
        return .keep;
    }

    fn onTunnelRead(
        raw: ?*anyopaque,
        packets: net.Looper.Packets,
    ) anyerror!net.Looper.ReadAction {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.receiveTunnel(packets);
        return .keep;
    }

    fn receiveLink(self: *Session, packets: []const []const u8) anyerror!void {
        std.debug.assert(self.looper.isOnQueue());
        const context = self.state.activeContext() orelse return;
        context.last_received_ns = core.concurrency.monotonicNs();
        var negotiator = context.currentNegotiator() orelse return error.Assertion;
        if (negotiator.shouldRenegotiate())
            negotiator = try self.startRenegotiationOnQueue(negotiator, .client);

        var grouped = [_]std.ArrayList([]const u8){.empty} **
            ControlChannelConstants.number_of_keys;
        defer for (&grouped) |*list| list.deinit(self.allocator);
        for (packets) |packet| {
            if (packet.len == 0) continue;
            const code = CPacketCode.fromRaw(packet[0] >> 3) orelse continue;
            if (code == .dataV2) {
                if (packet.len -| 1 < c.OpenVPNPacketPeerIdLength) continue;
            }

            if (code == .dataV1 or code == .dataV2) {
                const key = packet[0] & 0b111;
                if (context.dataChannel(key) == null) continue;
                try grouped[key].append(self.allocator, packet);
                continue;
            }

            try processDataPackets(context, &grouped);
            var parsed = negotiator.readInboundPacket(packet, 0) catch continue;
            defer parsed.deinit();
            negotiator.handleAcks();
            if (parsed.code == .ackV1) continue;
            switch (code) {
                .hardResetServerV2 => {
                    if (negotiator.isConnected()) return error.Recoverable;
                },
                .softResetV1 => {
                    if (!negotiator.isRenegotiating()) {
                        negotiator = try self.startRenegotiationOnQueue(negotiator, .server);
                    }
                },
                else => {},
            }
            negotiator.sendAck(&parsed);
            const inbound = try negotiator.enqueueInboundPacket(parsed.move());
            defer {
                for (inbound) |*owned| owned.deinit();
                self.allocator.free(inbound);
            }
            for (inbound) |*owned| try negotiator.handleControlPacket(owned);
        }
        try processDataPackets(context, &grouped);
    }

    fn processDataPackets(
        context: *ActiveContext,
        grouped: *[ControlChannelConstants.number_of_keys]std.ArrayList([]const u8),
    ) anyerror!void {
        const pair = context.current_data_pair orelse {
            for (grouped) |*list| list.clearRetainingCapacity();
            return;
        };
        for (grouped, 0..) |*list, key| {
            if (list.items.len > 0) try pair.receive(list.items, @intCast(key));
            list.clearRetainingCapacity();
        }
    }

    fn receiveTunnel(self: *Session, packets: []const []const u8) anyerror!void {
        std.debug.assert(self.looper.isOnQueue());
        const context = self.state.activeContext() orelse return;
        const pair = context.current_data_pair orelse return;
        try self.checkPingTimeoutOnQueue(context);
        try pair.send(packets, null, null);
    }

    fn startNegotiationOnQueue(self: *Session) anyerror!*NegotiatorV3 {
        const context = self.state.activeContext() orelse return error.Assertion;
        var tls = try self.tls_factory(self.allocator, TLSParameters{
            .fnt = self.fnt.tls,
            .caches_directory = self.caches_directory,
            .configuration = &self.configuration,
            .verification = .{ .context = self, .callback = onTLSVerificationFailure },
        });
        var tls_transferred = false;
        errdefer if (!tls_transferred) tls.deinit();
        const negotiator = try NegotiatorV3.create(self.allocator, .{
            .fnt = self.fnt,
            .looper = self.looper,
            .link_processor = self.link_processor orelse return error.Assertion,
            .remote_endpoint = &context.remote_endpoint,
            .channel = self.control_channel,
            .prng = self.prng,
            .tls = tls,
            .data_path_factory = self.data_path_factory,
            .options = self.negotiatorOptions(context.with_local_options),
        });
        tls_transferred = true;
        context.addNegotiator(negotiator);
        try negotiator.start();
        try self.scheduleNegotiationTick();
        return negotiator;
    }

    fn startRenegotiationOnQueue(
        self: *Session,
        previous: *NegotiatorV3,
        initiated_by: RenegotiationType,
    ) anyerror!*NegotiatorV3 {
        if (previous.isRenegotiating()) return previous;
        const context = self.state.activeContext() orelse return error.Assertion;
        const negotiator = try previous.forRenegotiation(initiated_by);
        context.addNegotiator(negotiator);
        try negotiator.start();
        try self.scheduleNegotiationTick();
        return negotiator;
    }

    fn negotiatorOptions(
        self: *Session,
        with_local_options: bool,
    ) NegotiatorOptions {
        return .{
            .configuration = &self.configuration,
            .credentials = if (self.credentials) |*value| value else null,
            .with_local_options = with_local_options,
            .session_options = self.options,
            .callback_context = self,
            .on_connected = onNegotiatorConnected,
            .on_error = onNegotiatorError,
        };
    }

    fn onNegotiatorConnected(
        raw: ?*anyopaque,
        key: u8,
        data_channel: *DataChannel,
        push_reply: *const PushReply,
    ) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const active = self.state.activeState() orelse return error.OperationCancelled;
        const context = active.context;
        var reply = try push_reply.clone(self.allocator);
        var reply_transferred = false;
        errdefer if (!reply_transferred) reply.deinit(self.allocator);
        try context.setDataChannel(data_channel, key);
        context.setPushReply(reply);
        reply_transferred = true;
        context.removeOldNegotiators();
        if (active.phase == .started) return;
        active.phase = .started;
        self.scheduleNextPing(context) catch |err| self.requestShutdown(err);
        if (self.delegate) |delegate| delegate.didStart(
            self,
            context.remote_endpoint,
            context.push_reply.?.options,
        );
    }

    fn onNegotiatorError(raw: ?*anyopaque, _: u8, cause: anyerror) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdown(cause);
    }

    fn onTLSVerificationFailure(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdown(error.TLSPeerVerification);
    }

    fn scheduleNegotiationTick(self: *Session) std.Thread.SpawnError!void {
        try self.negotiation_timer.init(
            self.options.tick_interval_ms,
            onNegotiationTimer,
            self,
        );
    }

    fn onNegotiationTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.looper.performTask(.{
            .context = self,
            .callback = negotiationTickOnQueue,
        }) catch |err| {
            if (err != error.Cancelled) self.requestShutdown(err);
        };
    }

    fn negotiationTickOnQueue(raw: ?*anyopaque) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return;
        const negotiator = context.currentNegotiator() orelse return error.Assertion;
        if (try negotiator.tick()) try self.scheduleNegotiationTick();
    }

    fn scheduleNextPing(
        self: *Session,
        context: *ActiveContext,
    ) std.Thread.SpawnError!void {
        const delay = self.keepAliveIntervalMs(context) orelse
            self.options.ping_timeout_check_interval_ms;
        try self.ping_timer.init(delay, onPingTimer, self);
    }

    fn onPingTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.looper.performTask(.{
            .context = self,
            .callback = pingOnQueue,
        }) catch |err| {
            if (err != error.Cancelled) self.requestShutdown(err);
        };
    }

    fn pingOnQueue(raw: ?*anyopaque) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return;
        const pair = context.current_data_pair orelse return;
        try self.checkPingTimeoutOnQueue(context);
        if (self.keepAliveIntervalMs(context) != null) {
            const ping: []const u8 = &@import("data_channel_constants.zig").DataChannel.ping_string;
            try pair.send(&.{ping}, null, null);
        }
        try self.scheduleNextPing(context);
    }

    fn checkPingTimeoutOnQueue(
        self: *Session,
        context: *ActiveContext,
    ) errors.PingTimeoutError!void {
        const last_received = context.last_received_ns orelse return;
        const timeout_ns = self.keepAliveTimeoutMs(context) *|
            @as(u64, std.time.ns_per_ms);
        if (core.concurrency.monotonicNs() -| last_received > timeout_ns)
            return error.PingTimeout;
    }

    fn keepAliveIntervalMs(
        self: *Session,
        context: *ActiveContext,
    ) ?u64 {
        if (context.push_reply) |reply| {
            if (reply.options.keep_alive_interval) |seconds|
                if (seconds > 0) return secondsToMilliseconds(seconds);
        }
        if (self.configuration.keep_alive_interval) |seconds|
            if (seconds > 0) return secondsToMilliseconds(seconds);
        return null;
    }

    fn keepAliveTimeoutMs(self: *Session, context: *ActiveContext) u64 {
        if (context.push_reply) |reply| {
            if (reply.options.keep_alive_timeout) |seconds|
                if (seconds > 0) return secondsToMilliseconds(seconds);
        }
        if (self.configuration.keep_alive_timeout) |seconds|
            if (seconds > 0) return secondsToMilliseconds(seconds);
        return self.options.ping_timeout_ms;
    }

    fn sendExitPacketOnQueue(self: *Session, timeout_ms: u64) anyerror!void {
        const context = self.state.activeContext() orelse return;
        if (context.remote_endpoint.plainSocketType() != .udp) return;
        const pair = context.current_data_pair orelse return;
        const exit = OCCPacket.exit.serialized();
        const packet: []const u8 = &exit;
        try pair.send(&.{packet}, null, timeout_ms);
    }

    fn dataChannelForKey(raw: ?*anyopaque, key: u8) ?*DataChannel {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return null;
        return context.dataChannel(key);
    }

    fn reportInboundDataCount(raw: ?*anyopaque, count: usize) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return;
        context.data_count.inbound +|= @intCast(count);
        self.delegateCurrentDataCount(context);
    }

    fn reportOutboundDataCount(raw: ?*anyopaque, count: usize) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return;
        context.data_count.outbound +|= @intCast(count);
        self.delegateCurrentDataCount(context);
    }

    fn delegateCurrentDataCount(self: *Session, context: *ActiveContext) void {
        const now = core.concurrency.monotonicNs();
        if (context.last_data_count_ns) |last| {
            const minimum = self.options.min_data_count_interval_ms *|
                @as(u64, std.time.ns_per_ms);
            if (now -| last < minimum) return;
        }
        context.last_data_count_ns = now;
        if (self.delegate) |delegate| delegate.didUpdateDataCount(self, .{
            .received = context.data_count.inbound,
            .sent = context.data_count.outbound,
        });
    }

    fn failureError(failure: net.Looper.Failure) anyerror {
        return switch (failure) {
            .user => |cause| cause,
            .io => |details| details.cause,
            .system => |cause| cause,
            else => error.NativeFailure,
        };
    }

    fn secondsToMilliseconds(seconds: f64) u64 {
        if (!(seconds > 0)) return 0;
        const milliseconds = seconds * 1000.0;
        if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            return std.math.maxInt(u64);
        return @intFromFloat(milliseconds);
    }

    const SetDelegateRequest = struct {
        session: *Session,
        delegate: ?SessionDelegate,
    };

    fn setDelegateOnQueue(raw: ?*anyopaque) anyerror!void {
        const request: *SetDelegateRequest = @ptrCast(@alignCast(raw.?));
        request.session.delegate = request.delegate;
    }

    const SetLinkRequest = struct {
        session: *Session,
        remote_endpoint: api.ExtendedEndpoint,
    };

    const ShutdownOnQueueRequest = struct {
        session: *Session,
        cause: ?anyerror,
        timeout_ms: ?u64,
    };

    const FinishShutdownRequest = struct {
        session: *Session,
        cause: ?anyerror,
    };

    const protocol_vtable = SessionProtocol.VTable{
        .set_delegate = protocolSetDelegate,
        .set_link = protocolSetLink,
        .has_link = protocolHasLink,
        .set_tunnel = protocolSetTunnel,
        .shutdown = protocolShutdown,
    };

    fn protocolSetDelegate(raw: *anyopaque, delegate: ?SessionDelegate) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.setDelegate(delegate);
    }

    fn protocolSetLink(
        raw: *anyopaque,
        descriptor: net.Looper.Descriptor,
        remote_endpoint: api.ExtendedEndpoint,
    ) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.setLink(descriptor, remote_endpoint);
    }

    fn protocolHasLink(raw: *anyopaque) bool {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.hasLink();
    }

    fn protocolSetTunnel(raw: *anyopaque, descriptor: net.Looper.Descriptor) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.setTunnel(descriptor);
    }

    fn protocolShutdown(
        raw: *anyopaque,
        cause: ?anyerror,
        timeout_ms: ?u64,
    ) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.shutdown(cause, timeout_ms);
    }
};

test "Session declarations are semantically analyzed" {
    std.testing.refAllDecls(Session);
}

test "Session borrows an externally managed Looper" {
    const Callbacks = struct {
        fn onFinish(_: ?*anyopaque, _: ?net.Looper.Failure) void {}

        fn barrier(_: ?*anyopaque) anyerror!void {}
    };

    const allocator = std.testing.allocator;
    var looper = try net.Looper.init(allocator, .{
        .on_finish = .{ .callback = Callbacks.onFinish },
    });
    defer looper.deinit();
    try looper.start();
    var looper_started = true;
    defer if (looper_started) looper.stop() catch {};

    const session = try Session.create(
        allocator,
        &looper,
        c.pp_crypto_fnt_mock(),
        .{},
        null,
        PRNG.system(),
        "",
        .{},
        @import("factories.zig").nativeTLSFactory,
        @import("factories.zig").nativeDataPathFactory,
    );
    var session_destroyed = false;
    defer if (!session_destroyed) session.destroy();
    try std.testing.expect(session.looper == &looper);

    session.destroy();
    session_destroyed = true;

    // Destruction only drains Session work. The owner can still use and then
    // stop the same Looper before deinitializing it.
    try looper.perform(void, null, Callbacks.barrier);
    try looper.stop();
    looper_started = false;
}
