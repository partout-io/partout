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
    lifecycle_lock: core.Mutex = .{},
    negotiation_timer: core.RunAfter = .{},
    ping_timer: core.RunAfter = .{},

    delegate: ?SessionDelegate = null,
    state: SessionState = .{ .stopped = .{ .with_local_options = true } },
    link_processor: ?*LinkProcessor = null,

    shutdown_request_lock: core.Mutex = .{},
    shutdown_pending: bool = false,
    shutdown_request_cause: ?SessionError = null,

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

    pub fn create(allocator: std.mem.Allocator, init: Init) Error!*Session {
        return createUnwrapped(allocator, init) catch |err| errors_mod.sessionError(err);
    }

    fn createUnwrapped(allocator: std.mem.Allocator, init: Init) !*Session {
        var owned_configuration = try init.configuration.clone(allocator);
        errdefer owned_configuration.deinit(allocator);
        var owned_credentials = if (init.credentials) |value|
            try forAuthentication(allocator, value)
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
        };
        return self;
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
        self.shutdown_request_lock.deinit();
        self.lifecycle_lock.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn setDelegate(self: *Session, delegate: ?SessionDelegate) void {
        if (self.looper.isOnQueue()) {
            self.delegate = delegate;
            return;
        }
        _ = self.performOnQueue(void, delegate, setDelegateOnQueue) catch {};
    }

    pub fn setLink(
        self: *Session,
        descriptor: net.Looper.Descriptor,
        remote_endpoint: api.ExtendedEndpoint,
    ) Error!void {
        return self.setLinkUnwrapped(descriptor, remote_endpoint) catch |err|
            errors_mod.sessionError(err);
    }

    fn setLinkUnwrapped(
        self: *Session,
        descriptor: net.Looper.Descriptor,
        remote_endpoint: api.ExtendedEndpoint,
    ) !void {
        var descriptor_transferred = false;
        defer if (!descriptor_transferred) descriptor.io.cleanup();

        if (self.looper.isOnQueue()) return error.ReentrantCall;
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        if (self.looper.isLinkAttached()) {
            log.write(.err, "Link interface already set");
            return;
        }

        const processor = try LinkProcessor.create(
            self.allocator,
            self.configuration.xor_method,
            remote_endpoint.plainSocketType() == .tcp,
        );
        self.link_processor = processor;
        errdefer {
            if (self.link_processor == processor) {
                self.link_processor = null;
                processor.destroy();
            }
        }

        log.write(.info, "Attach LINK");
        try self.looper.attach(.{
            .pair = .{ .link = descriptor },
            .on_read = .{ .context = self, .callback = onLinkRead },
            .on_failure = .{ .context = self, .callback = onLinkFailure },
        });
        descriptor_transferred = true;
        errdefer self.looper.detach(.link) catch {};
        try self.performOnQueue(void, remote_endpoint, setLinkOnQueue);
    }

    pub fn setTunnel(self: *Session, descriptor: net.Looper.Descriptor) Error!void {
        return self.setTunnelUnwrapped(descriptor) catch |err|
            errors_mod.sessionError(err);
    }

    fn setTunnelUnwrapped(self: *Session, descriptor: net.Looper.Descriptor) !void {
        errdefer descriptor.io.cleanup();

        if (self.looper.isOnQueue()) return error.ReentrantCall;
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
        try self.looper.attach(.{
            .pair = .{ .tun = descriptor },
            .on_read = .{ .context = self, .callback = onTunnelRead },
            .on_failure = .{ .context = self, .callback = onSideFailure },
        });
    }

    /// Prepares state on the looper, detaches from this external thread, then
    /// finishes state on the looper.
    pub fn shutdown(
        self: *Session,
        cause: ?SessionError,
        timeout_ms: ?u64,
    ) Error!void {
        if (!self.claimShutdown()) return;
        return self.shutdownUnwrapped(cause, timeout_ms) catch |err|
            errors_mod.sessionError(err);
    }

    fn shutdownUnwrapped(
        self: *Session,
        cause: ?SessionError,
        timeout_ms: ?u64,
    ) !void {
        if (self.looper.isOnQueue()) return error.ReentrantCall;
        self.lifecycle_lock.lock();
        defer self.lifecycle_lock.unlock();
        const request = ShutdownRequest{
            .cause = cause,
            .timeout_ms = timeout_ms,
        };
        const should_detach = self.performOnQueue(
            bool,
            request,
            prepareShutdownOnQueue,
        ) catch |err| {
            // A stopped looper has already serialized final state; its owner
            // routes `OnFinish` through `looperDidTerminate` while Session lives.
            if (err == error.Cancelled) return;
            log.writef(.err, "Unable to shut down session on looper queue: {s}", .{
                @errorName(err),
            });
            return err;
        };
        if (!should_detach) return;
        // Detach is best-effort, matching Swift's nonthrowing detach calls.
        // State must still leave `.stopping` if a side failed independently.
        if (self.looper.isTunAttached()) self.looper.detach(.tun) catch {};
        if (self.looper.isLinkAttached()) self.looper.detach(.link) catch {};
        try self.performOnQueue(void, cause, finishShutdownOnQueue);
    }

    fn requestShutdown(self: *Session, cause: SessionError) void {
        self.shutdown_request_lock.lock();
        defer self.shutdown_request_lock.unlock();
        if (self.shutdown_pending) return;
        self.shutdown_pending = true;

        self.shutdown_request_cause = cause;
        self.executor.run(self, shutdownOnExecutor);
    }

    fn shutdownOnExecutor(raw: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.shutdown_request_lock.lock();
        const cause = self.shutdown_request_cause;
        self.shutdown_request_lock.unlock();
        self.shutdownUnwrapped(cause orelse return, null) catch |err| {
            log.writef(.err, "Unable to shut down session on looper queue: {s}", .{
                @errorName(err),
            });
        };
    }

    fn claimShutdown(self: *Session) bool {
        self.shutdown_request_lock.lock();
        defer self.shutdown_request_lock.unlock();
        if (self.shutdown_pending) return false;
        self.shutdown_pending = true;
        return true;
    }

    fn setLinkOnQueue(
        self: *Session,
        remote_endpoint: api.ExtendedEndpoint,
    ) !void {
        std.debug.assert(self.looper.isOnQueue());
        const idle = switch (self.state) {
            .stopped => |context| context,
            .active => {
                log.write(.err, "Session is not stopped");
                return error.OperationCancelled;
            },
        };
        log.write(.info, "Start VPN session");
        const processor = self.link_processor orelse
            @panic("Session cannot start before its link processor is configured");
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
            remote_endpoint,
        );
        self.state = .{ .active = .{
            .phase = .starting,
            .context = active_context,
        } };
        self.startNegotiationOnQueue() catch |err| {
            active_context.destroy();
            self.state = .{ .stopped = idle };
            return err;
        };
    }

    fn prepareShutdownOnQueue(
        self: *Session,
        request: ShutdownRequest,
    ) !bool {
        std.debug.assert(self.looper.isOnQueue());
        const active = self.state.activeState() orelse {
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
        self.negotiation_timer.cancel();
        self.ping_timer.cancel();

        if (shouldSendExitNotification(request.cause)) self.sendExitPacketOnQueue(
            request.timeout_ms orelse self.options.write_timeout_ms,
        ) catch |err| {
            log.writef(.err, "Unable to send exit packet: {s}", .{@errorName(err)});
        };
        return true;
    }

    fn finishShutdownOnQueue(self: *Session, cause: ?SessionError) !void {
        self.finishShutdown(cause);
    }

    fn finishShutdown(self: *Session, cause: ?SessionError) void {
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
        const next_with_local_options = if (cause) |value|
            active.context.with_local_options and value != error.BadCredentialsWithLocalOptions
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
    pub fn looperDidTerminate(self: *Session, failure: ?net.Looper.Failure) void {
        std.debug.assert(self.looper.isOnQueue());
        _ = self.claimShutdown();
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
        self.finishShutdown(if (failure) |value| failureError(value) else null);
    }

    fn onSideFailure(raw: ?*anyopaque, failure: net.Looper.Failure) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdown(failureError(failure));
    }

    fn onLinkFailure(raw: ?*anyopaque, failure: net.Looper.Failure) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const cause = failureError(failure);
        self.requestShutdown(if (cause == error.CryptoFailure) error.Reconnect else cause);
    }

    fn onLinkRead(
        raw: ?*anyopaque,
        packets: net.Looper.Packets,
    ) !net.Looper.ReadAction {
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
    ) !net.Looper.ReadAction {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        try self.receiveTunnel(packets);
        return .keep;
    }

    fn receiveLink(self: *Session, packets: []const []const u8) !void {
        std.debug.assert(self.looper.isOnQueue());
        const context = self.state.activeContext() orelse return;
        context.last_received_ns = core.concurrency.monotonicNs();
        var negotiator = context.currentNegotiator() orelse {
            @panic("Active session received link packets without a negotiator");
        };
        if (negotiator.shouldRenegotiate())
            negotiator = try self.startRenegotiationOnQueue(negotiator, .client);

        var grouped = [_]std.ArrayList([]const u8){.empty} **
            ControlConstants.number_of_keys;
        defer for (&grouped) |*list| list.deinit(self.allocator);
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
                try grouped[key].append(self.allocator, packet);
                continue;
            }

            try processDataPackets(context, &grouped);
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
                        return error.Reconnect;
                    }
                },
                .softResetV1 => {
                    negotiator = try self.startRenegotiationOnQueue(negotiator, .server);
                },
                else => {},
            }
            negotiator.sendAck(&parsed);
            const inbound = try self.control_channel.enqueueInboundPacket(parsed.move());
            defer {
                for (inbound) |*owned| owned.deinit();
                self.allocator.free(inbound);
            }
            for (inbound) |*owned| {
                log.writef(.debug, "Handle packet: {d}", .{owned.packetId()});
                try negotiator.handleControlPacket(owned);
            }
        }
        try processDataPackets(context, &grouped);
    }

    fn processDataPackets(
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

    fn receiveTunnel(self: *Session, packets: []const []const u8) !void {
        std.debug.assert(self.looper.isOnQueue());
        const context = self.state.activeContext() orelse return;
        const pair = context.current_data_pair orelse return;
        try self.checkPingTimeoutOnQueue(context);
        try pair.send(packets, null, null);
    }

    fn startNegotiationOnQueue(self: *Session) !void {
        log.write(.info, "Start negotiation");
        const context = self.state.activeContext() orelse
            @panic("Cannot start negotiation while the session is stopped");
        const tls = try TLSWrapper.create(self.allocator, .{
            .backend = self.options.backend,
            .caches_directory = self.caches_directory,
            .ca_filename = self.ca_filename,
            .configuration = &self.configuration,
            .verification = .{ .context = self, .callback = onTLSVerificationFailure },
        });
        var tls_transferred = false;
        errdefer if (!tls_transferred) tls.destroy();
        const negotiator = try Negotiator.create(self.allocator, .{
            .looper = self.looper,
            .link_processor = self.link_processor orelse
                @panic("Cannot start negotiation before the link processor is configured"),
            .remote_endpoint = &context.remote_endpoint,
            .channel = self.control_channel,
            .prng = self.prng,
            .tls = tls,
            .options = .{
                .configuration = &self.configuration,
                .credentials = if (self.credentials) |*value| value else null,
                .with_local_options = context.with_local_options,
                .session_options = self.options,
                .callback_context = self,
                .on_connected = onNegotiatorConnected,
                .on_error = onNegotiatorError,
            },
        });
        tls_transferred = true;
        context.addNegotiator(negotiator);
        try negotiator.start();
        try self.scheduleNegotiationTick();
    }

    fn startRenegotiationOnQueue(
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
        context.addNegotiator(negotiator);
        try negotiator.start();
        try self.scheduleNegotiationTick();
        return negotiator;
    }

    fn onNegotiatorConnected(
        raw: ?*anyopaque,
        key: u8,
        data_channel: *DataChannel,
        push_reply: *const PushReply,
    ) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const active = self.state.activeState() orelse return error.Reconnect;
        const context = active.context;
        log.writef(.info, "Negotiation succeeded, set key {d} as current", .{key});
        var reply = push_reply.clone(self.allocator) catch |err|
            return errors_mod.sessionError(err);
        errdefer reply.deinit(self.allocator);
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
            self.requestShutdown(errors_mod.sessionError(err));
        if (self.delegate) |delegate| delegate.didStart(
            self,
            context.remote_endpoint,
            &context.push_reply.?.options,
        );
    }

    fn onNegotiatorError(raw: ?*anyopaque, _: u8, cause: SessionError) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdown(cause);
    }

    fn onTLSVerificationFailure(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.requestShutdown(error.TLSFailure);
    }

    fn scheduleNegotiationTick(self: *Session) !void {
        try self.negotiation_timer.scheduleReplacing(
            self.options.tick_interval_ms,
            onNegotiationTimer,
            self,
        );
    }

    fn onNegotiationTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.performTimerTask(negotiationTickOnQueue);
    }

    fn negotiationTickOnQueue(raw: ?*anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse return;
        const negotiator = context.currentNegotiator() orelse
            @panic("Active session negotiation timer fired without a negotiator");
        if (try negotiator.tick()) try self.scheduleNegotiationTick();
    }

    fn scheduleNextPing(
        self: *Session,
        context: *ActiveContext,
    ) !void {
        const delay = self.keepAliveIntervalMs(context) orelse
            self.options.ping_timeout_check_interval_ms;
        log.logTimeMs(.debug, "Schedule ping check after ", delay);
        try self.ping_timer.scheduleReplacing(delay, onPingTimer, self);
    }

    fn onPingTimer(raw: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        self.performTimerTask(pingOnQueue);
    }

    fn performTimerTask(
        self: *Session,
        callback: *const fn (?*anyopaque) anyerror!void,
    ) void {
        self.looper.performTask(.{
            .context = self,
            .callback = callback,
        }) catch |err| {
            if (err != error.Cancelled) self.requestShutdown(errors_mod.sessionError(err));
        };
    }

    fn pingOnQueue(raw: ?*anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw.?));
        const context = self.state.activeContext() orelse {
            log.write(.debug, "Ping cancelled, session stopped");
            return;
        };
        const pair = context.current_data_pair orelse {
            log.write(.debug, "Ping cancelled, no data link");
            return;
        };
        log.write(.debug, "Run ping check");
        try self.checkPingTimeoutOnQueue(context);
        if (self.keepAliveIntervalMs(context) != null) {
            log.write(.debug, "Send ping");
            const ping: []const u8 = &constants_mod.Data.ping_string;
            try pair.send(&.{ping}, null, null);
        }
        try self.scheduleNextPing(context);
    }

    fn checkPingTimeoutOnQueue(
        self: *const Session,
        context: *ActiveContext,
    ) !void {
        const last_received = context.last_received_ns orelse return;
        const deadline = core.concurrency.deadlineAfterMs(
            last_received,
            self.keepAliveTimeoutMs(context),
        );
        if (core.concurrency.monotonicNs() > deadline)
            return error.Timeout;
    }

    fn keepAliveIntervalMs(
        self: *const Session,
        context: *ActiveContext,
    ) ?u64 {
        const pushed = if (context.push_reply) |reply|
            reply.options.keep_alive_interval
        else
            null;
        return keepAliveMilliseconds(pushed, self.configuration.keep_alive_interval);
    }

    fn keepAliveTimeoutMs(self: *const Session, context: *ActiveContext) u64 {
        const pushed = if (context.push_reply) |reply|
            reply.options.keep_alive_timeout
        else
            null;
        return keepAliveMilliseconds(pushed, self.configuration.keep_alive_timeout) orelse
            self.options.ping_timeout_ms;
    }

    fn keepAliveMilliseconds(pushed: ?f64, configured: ?f64) ?u64 {
        for ([_]?f64{ pushed, configured }) |candidate| {
            const seconds = candidate orelse continue;
            if (seconds > 0) return core.util.secondsToMilliseconds(seconds);
        }
        return null;
    }

    fn sendExitPacketOnQueue(self: *Session, timeout_ms: u64) !void {
        const context = self.state.activeContext() orelse return;
        if (context.remote_endpoint.plainSocketType() != .udp) return;
        const pair = context.current_data_pair orelse return;
        log.write(.info, "Send OCCPacket exit");
        const exit = OCCPacket.exit.serialized();
        const packet: []const u8 = &exit;
        try pair.send(&.{packet}, null, timeout_ms);
        log.write(.info, "Sent OCCPacket correctly");
    }

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
        self.delegateCurrentDataCount(context);
    }

    fn delegateCurrentDataCount(self: *Session, context: *ActiveContext) void {
        const now = core.concurrency.monotonicNs();
        if (context.last_data_count_ns) |last| {
            const next = core.concurrency.deadlineAfterMs(
                last,
                self.options.min_data_count_interval_ms,
            );
            if (self.options.min_data_count_interval_ms > 0 and now < next) return;
        }
        context.last_data_count_ns = now;
        if (self.delegate) |delegate| delegate.didUpdateDataCount(self, .{
            .received = context.data_count.inbound,
            .sent = context.data_count.outbound,
        });
    }

    fn failureError(failure: net.Looper.Failure) SessionError {
        return switch (failure) {
            .user, .system => |cause| errors_mod.sessionError(cause),
            .io => |details| errors_mod.sessionError(details.cause),
            .wait => |code| {
                log.writef(.err, "OpenVPN looper wait failed with native code: {}", .{code});
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
                return callback(request.session, request.arguments);
            }
        };
        var request = Request{ .session = self, .arguments = arguments };
        return self.looper.perform(Result, &request, Request.run);
    }

    fn setDelegateOnQueue(self: *Session, delegate: ?SessionDelegate) !void {
        self.delegate = delegate;
    }

    const ShutdownRequest = struct {
        cause: ?SessionError,
        timeout_ms: ?u64,
    };
};

fn forAuthentication(
    allocator: std.mem.Allocator,
    credentials: api.OpenVPNCredentials,
) !api.OpenVPNCredentials {
    const username = try allocator.dupe(u8, credentials.username);
    errdefer allocator.free(username);

    const password = switch (credentials.otp_method) {
        .none => try allocator.dupe(u8, credentials.password),
        .append => blk: {
            const otp = credentials.otp orelse return error.OTPRequired;
            break :blk try std.mem.concat(allocator, u8, &.{ credentials.password, otp });
        },
        .encode => blk: {
            const otp = credentials.otp orelse return error.OTPRequired;
            const encoded_password = try core.util.base64EncodeAlloc(allocator, credentials.password);
            defer allocator.free(encoded_password);
            const encoded_otp = try core.util.base64EncodeAlloc(allocator, otp);
            defer allocator.free(encoded_otp);
            break :blk try std.fmt.allocPrint(
                allocator,
                "SCRV1:{s}:{s}",
                .{ encoded_password, encoded_otp },
            );
        },
    };

    return .{
        .username = username,
        .password = password,
        .otp_method = .none,
        .otp = null,
    };
}

fn shouldSendExitNotification(cause: ?SessionError) bool {
    return if (cause) |value| value == error.NetworkChanged else true;
}

pub const testing = struct {
    pub const forAuthentication = session_mod.forAuthentication;
    pub const shouldSendExitNotification = session_mod.shouldSendExitNotification;
};
