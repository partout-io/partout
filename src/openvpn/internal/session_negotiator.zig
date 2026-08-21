// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const net_mod = @import("../../net/exports.zig");
const auth_mod = @import("auth.zig");
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
const tls_mod = @import("tls.zig");

const api = core_mod.api;
const log = core_mod.logging;

const Authenticator = auth_mod.Authenticator;
const SessionOptions = configuration_mod.SessionOptions;
const ControlChannel = control_mod.ControlChannel(control_serializers_mod.Serializer);
const ControlConstants = constants_mod.Control;
const ControlPacket = packet_mod.ControlPacket;
const DataChannel = data_mod.DataChannel;
const DataPath = data_mod.DataPath;
const LinkProcessor = processing_mod.LinkProcessor;
const PacketCode = packet_mod.PacketCode;
const PRF = auth_mod.PRF;
const PRNG = crypto_mod.PRNG;
const PushReply = push_mod.PushReply;
const TLSWrapper = tls_mod.TLSWrapper;

pub const RenegotiationType = enum {
    client,
    server,
};

/// Ordered phases of an OpenVPN key negotiation.
pub const NegotiatorState = enum(u8) {
    idle,
    tls,
    auth,
    push,
    connected,

    pub fn before(self: NegotiatorState, other: NegotiatorState) bool {
        return @intFromEnum(self) < @intFromEnum(other);
    }
};

/// Borrowed session settings and callbacks used by a negotiator.
///
/// `on_connected` transfers the `DataChannel` to the callback on success. The
/// push reply remains borrowed from the negotiator and must be cloned by a
/// recipient that needs to retain it.
pub const NegotiatorOptions = struct {
    configuration: *const api.OpenVPNConfiguration,
    credentials: ?*const api.OpenVPNCredentials,
    with_local_options: bool,
    session_options: SessionOptions,
    callback_context: ?*anyopaque,
    // The Session owns the stable timer worker; this callback lets the
    // Negotiator own when its next check is armed.
    schedule_negotiation_check: *const fn (
        ?*anyopaque,
        u64,
    ) std.Thread.SpawnError!void,
    on_connected: *const fn (
        ?*anyopaque,
        u8,
        *DataChannel,
        *const PushReply,
    ) errors_mod.SessionError!void,
    on_error: *const fn (?*anyopaque, u8, errors_mod.SessionError) void,
};

/// V3 control-channel state machine. All mutable methods run on `looper`.
pub const Negotiator = struct {
    allocator: std.mem.Allocator,
    key: u8,
    history: ?PushReply,
    renegotiation: ?RenegotiationType,
    looper: *net_mod.Looper,
    link_processor: *LinkProcessor,
    remote_endpoint: *const api.ExtendedEndpoint,
    channel: *ControlChannel,
    prng: PRNG,
    tls: ?*TLSWrapper,
    options: NegotiatorOptions,

    start_time_ns: u64,
    negotiation_timeout_ms: u64,
    state: NegotiatorState,
    authenticator: ?Authenticator,
    next_push_request_ns: ?u64,
    continued_push_reply_message: ?[]u8,
    should_resend_wrapped_key: bool,

    pub const Init = struct {
        key: u8 = 0,
        history: ?PushReply = null,
        renegotiation: ?RenegotiationType = null,
        looper: *net_mod.Looper,
        link_processor: *LinkProcessor,
        remote_endpoint: *const api.ExtendedEndpoint,
        channel: *ControlChannel,
        prng: PRNG,
        tls: *TLSWrapper,
        options: NegotiatorOptions,

        fn negotiationTimeoutMs(self: *const Init) u64 {
            // Renegotiation has a more tolerant timeout.
            return if (self.renegotiation != null)
                self.options.session_options.soft_negotiation_timeout_ms
            else
                self.options.session_options.negotiation_timeout_ms;
        }
    };

    /// `tls` and `history` transfer only when creation succeeds.
    pub fn create(allocator: std.mem.Allocator, init: Init) !*Negotiator {
        const self = try allocator.create(Negotiator);
        self.* = .{
            .allocator = allocator,
            .key = init.key,
            .history = init.history,
            .renegotiation = init.renegotiation,
            .looper = init.looper,
            .link_processor = init.link_processor,
            .remote_endpoint = init.remote_endpoint,
            .channel = init.channel,
            .prng = init.prng,
            .tls = init.tls,
            .options = init.options,
            .start_time_ns = core_mod.concurrency.monotonicNs(),
            .negotiation_timeout_ms = init.negotiationTimeoutMs(),
            .state = .idle,
            .authenticator = null,
            .next_push_request_ns = null,
            .continued_push_reply_message = null,
            .should_resend_wrapped_key = false,
        };
        return self;
    }

    pub fn destroy(self: *Negotiator) void {
        log.write(.debug, "Deinit OpenVPN.Negotiator");
        if (self.authenticator) |*authenticator| authenticator.deinit();
        if (self.history) |*history| history.deinit(self.allocator);
        if (self.continued_push_reply_message) |message| self.allocator.free(message);
        if (self.tls) |tls| tls.destroy();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn forRenegotiation(
        self: *Negotiator,
        initiated_by: RenegotiationType,
    ) !*Negotiator {
        const history = if (self.history) |value|
            try value.clone(self.allocator)
        else {
            log.write(.err, "Negotiator has no history (not connected yet?)");
            // The Swift implementation deliberately keeps using the current
            // negotiator when a premature SOFT_RESET arrives before history
            // exists.
            return self;
        };
        errdefer {
            var owned_history = history;
            owned_history.deinit(self.allocator);
        }

        const tls = self.tls orelse
            @panic("Cannot transfer TLS state from a negotiator that no longer owns it");
        self.tls = null;
        errdefer self.tls = tls;
        return create(self.allocator, .{
            .key = ControlConstants.nextKey(self.key),
            .history = history,
            .renegotiation = initiated_by,
            .looper = self.looper,
            .link_processor = self.link_processor,
            .remote_endpoint = self.remote_endpoint,
            .channel = self.channel,
            .prng = self.prng,
            .tls = tls,
            .options = self.options,
        });
    }

    pub fn isConnected(self: *const Negotiator) bool {
        return self.state == .connected;
    }

    pub fn isRenegotiating(self: *const Negotiator) bool {
        return self.renegotiation != null and self.state != .connected;
    }

    fn usesTLSCryptV2(self: *const Negotiator) bool {
        const wrap = self.options.configuration.tls_wrap orelse return false;
        return wrap.strategy == .cryptV2;
    }

    pub fn start(self: *Negotiator) !void {
        std.debug.assert(self.looper.isOnQueue());
        try self.channel.reset(self.renegotiation == null);
        try self.checkNegotiation();

        if (self.renegotiation) |kind| {
            if (kind == .client) try self.enqueueControlPackets(.softResetV1, "");
            return;
        }

        const uses_pia_patches = self.options.configuration.uses_pia_patches orelse false;
        const ca_md5_digest: ?[]u8 = if (uses_pia_patches) blk: {
            const tls = self.tls orelse
                @panic("Initial negotiation requires an owned TLS session");
            const digest = tls.caMD5(self.allocator) catch {
                log.write(.err, "PIA CA MD5 could not be computed, skip custom HARD_RESET");
                break :blk null;
            };
            log.writef(.info, "PIA CA MD5 is: {s}", .{digest});
            break :blk digest;
        } else null;
        defer if (ca_md5_digest) |digest| self.allocator.free(digest);
        const hard_reset_payload = packet_mod.hardResetPayload(
            self.allocator,
            uses_pia_patches,
            ca_md5_digest,
            configuration_mod.fallbackCipher(self.options.configuration).raw(),
            configuration_mod.fallbackDigest(self.options.configuration).raw(),
            self.prng,
        );
        defer if (hard_reset_payload) |payload| self.allocator.free(payload);
        try self.enqueueControlPackets(
            if (self.usesTLSCryptV2()) .hardResetClientV3 else .hardResetClientV2,
            hard_reset_payload orelse "",
        );
    }

    /// Performs and rearms the former recursive `Task.sleep` check.
    pub fn checkNegotiation(self: *Negotiator) !void {
        std.debug.assert(self.looper.isOnQueue());
        const elapsed = self.elapsedMs();
        if (self.state == .idle and elapsed > self.options.session_options.hard_reset_timeout_ms) {
            log.write(.notice, "OpenVPN hard reset timed out; reconnecting");
            return error.Reconnect;
        }
        if (self.state != .connected and elapsed > self.negotiation_timeout_ms)
            return error.Timeout;

        if (!self.isRenegotiating()) try self.pushRequest();
        if (self.remote_endpoint.plainSocketType() == .udp) try self.flushControlQueue();
        if (self.state != .connected) {
            try self.options.schedule_negotiation_check(
                self.options.callback_context,
                self.options.session_options.tick_interval_ms,
            );
        }
    }

    pub fn sendAck(self: *const Negotiator, packet: *const ControlPacket) void {
        log.writef(.info, "Send ack for received packetId {d}", .{packet.packetId()});
        self.sendAckToLink(packet) catch |err| {
            log.writef(.err, "Failed LINK write during send ack for packetId {d}: {s}", .{
                packet.packetId(),
                @errorName(err),
            });
            self.options.on_error(
                self.options.callback_context,
                self.key,
                errors_mod.sessionError(err),
            );
            return;
        };
        log.writef(.info, "Ack successfully written to LINK for packetId {d}", .{
            packet.packetId(),
        });
    }

    fn sendAckToLink(self: *const Negotiator, packet: *const ControlPacket) !void {
        const raw = try self.channel.writeAcks(
            packet.key(),
            &.{packet.packetId()},
            packet.sessionId(),
        );
        defer self.allocator.free(raw);
        try self.writeLink(&.{raw});
    }

    pub fn shouldRenegotiate(self: *const Negotiator) bool {
        if (self.state != .connected) return false;
        const seconds = self.options.configuration.renegotiates_after orelse return false;
        if (seconds <= 0) return false;
        return self.elapsedMs() >= core_mod.util.secondsToMilliseconds(seconds);
    }

    fn pushRequest(self: *Negotiator) !void {
        if (self.state != .push) return;
        const next = self.next_push_request_ns orelse return;
        if (core_mod.concurrency.monotonicNs() <= next) return;
        const tls = self.tls orelse
            @panic("Cannot send a push request without an owned TLS session");
        log.write(.info, "TLS.ifconfig: Put plaintext (PUSH_REQUEST)");
        tls.putPlainText("PUSH_REQUEST\x00") catch {};
        if (!try self.sendAvailableCipherText(tls)) return;
        self.next_push_request_ns = core_mod.concurrency.deadlineAfterMs(
            core_mod.concurrency.monotonicNs(),
            self.options.session_options.push_request_interval_ms,
        );
    }

    fn enqueueControlPackets(
        self: *Negotiator,
        code: PacketCode,
        payload: []const u8,
    ) !void {
        var leading_code = code;
        var leading_limit = ControlConstants.max_payload_bytes_per_packet;
        if (code == .controlV1 and self.should_resend_wrapped_key) {
            self.should_resend_wrapped_key = false;
            leading_code = .controlWkcV1;
            const wrapped_length = self.wrappedKeyLength();
            if (wrapped_length > leading_limit) return error.ControlChannelFailure;
            leading_limit -= wrapped_length;
        }
        try self.channel.enqueueOutboundPackets(
            leading_code,
            code,
            self.key,
            payload,
            leading_limit,
            ControlConstants.max_payload_bytes_per_packet,
        );
        try self.flushControlQueue();
    }

    fn flushControlQueue(self: *const Negotiator) !void {
        const raw_packets = self.channel.writeOutboundPackets(
            @intCast(self.options.session_options.retransmission_interval_ms),
        ) catch |err| {
            log.writef(.err, "Failed control packet serialization: {s}", .{@errorName(err)});
            return err;
        };
        defer core_mod.util.freeSliceOfStrings(self.allocator, raw_packets);
        if (raw_packets.len == 0) return;
        for (raw_packets) |_|
            log.write(.info, "Send control packet");
        try self.writeLink(@ptrCast(raw_packets));
    }

    fn writeLink(self: *const Negotiator, packets: []const []const u8) !void {
        var processed = try self.link_processor.processOutbound(packets);
        defer processed.deinit();
        try self.looper.writeQueued(processed.packets(), .link);
    }

    fn requestsWrappedKeyResend(payload: ?[]const u8) bool {
        const bytes = payload orelse return false;
        var offset: usize = 0;
        while (offset + 4 <= bytes.len) {
            const value_type = std.mem.readInt(u16, bytes[offset..][0..2], .big);
            offset += 2;
            const length = std.mem.readInt(u16, bytes[offset..][0..2], .big);
            offset += 2;
            if (offset + length > bytes.len) {
                log.write(.err, "Malformed early-negotiation payload in HARD_RESET");
                return false;
            }
            if (value_type == ControlConstants.early_negotiation_flags_type and length >= 2) {
                const flags = std.mem.readInt(u16, bytes[offset..][0..2], .big);
                return flags & ControlConstants.early_negotiation_resend_wrapped_key != 0;
            }
            offset += length;
        }
        return false;
    }

    pub fn handleControlPacket(
        self: *Negotiator,
        packet: *ControlPacket,
    ) !void {
        if (packet.key() != self.key) {
            log.writef(.err, "Bad key in control packet ({d} != {d})", .{
                packet.key(),
                self.key,
            });
            return;
        }

        if (self.state == .idle) {
            if (packet.code != .hardResetServerV2 and packet.code != .softResetV1) return;
            if (packet.code == .hardResetServerV2) {
                if (self.isRenegotiating())
                    log.write(.err, "Sent SOFT_RESET but received HARD_RESET?");
                try self.channel.setRemoteSessionId(packet.sessionId());
                self.should_resend_wrapped_key = self.usesTLSCryptV2() and
                    requestsWrappedKeyResend(packet.payload());
            }
        } else if (packet.code != .controlV1) return;

        const remote_session_id = self.channel.remoteSessionId() orelse {
            log.write(.fault, "No remote sessionId found in control channel: MissingSessionId");
            return error.MissingSessionId;
        };
        if (!std.mem.eql(u8, packet.sessionId(), remote_session_id)) {
            log.writef(.fault, "Packet session mismatch ({x} != {x}): SessionMismatch", .{
                packet.sessionId(),
                remote_session_id,
            });
            return error.SessionMismatch;
        }

        switch (self.state) {
            .idle => {
                log.write(.info, "Start TLS handshake");
                self.setState(.tls);
                const tls = self.tls orelse
                    @panic("Cannot start the TLS handshake without an owned TLS session");
                try tls.start();
                const ciphertext = tls.pullCipherText(self.allocator) catch |err| {
                    log.writef(.fault, "TLS.connect: Failed pulling ciphertext: {s}", .{
                        @errorName(err),
                    });
                    return err;
                };
                defer self.allocator.free(ciphertext);
                log.write(.info, "TLS.connect: Pulled ciphertext");
                try self.enqueueControlPackets(.controlV1, ciphertext);
            },
            .tls, .auth, .push, .connected => {
                const payload = packet.payload() orelse {
                    log.write(.err, "TLS.connect: Control packet with empty payload?");
                    return;
                };
                const tls = self.tls orelse
                    @panic("Cannot process TLS control data without an owned TLS session");
                log.writef(.info, "TLS.connect: Put received ciphertext [{d}]", .{
                    packet.packetId(),
                });
                tls.putCipherText(payload) catch {};
                _ = try self.sendAvailableCipherText(tls);

                if (self.state.before(.auth) and tls.isConnected()) {
                    log.write(.info, "TLS.connect: Handshake is complete");
                    self.setState(.auth);
                    try self.onTLSConnect();
                }
                while (true) {
                    // This mirrors the broad do/catch around
                    // currentControlData(withTLS:) and handleControlData():
                    // message handlers notify on_error where appropriate,
                    // then this TLS-drain pass stops without failing LINK.
                    const control_data = tls.pullPlainText(self.allocator) catch break;
                    defer self.allocator.free(control_data);
                    self.handleControlData(control_data) catch break;
                }
            },
        }
    }

    fn onTLSConnect(self: *Negotiator) !void {
        const credentials = self.options.credentials;
        const username = if (credentials) |value| value.username else null;
        const configured_password = if (credentials) |value| value.password else null;
        const password = if (self.history) |*history|
            history.options.auth_token orelse configured_password
        else
            configured_password;
        if (self.authenticator) |*old| old.deinit();
        self.authenticator = try Authenticator.init(
            self.allocator,
            self.prng,
            username,
            password,
        );
        const authenticator = &self.authenticator.?;
        authenticator.with_local_options = self.options.with_local_options;
        const tls = self.tls orelse
            @panic("Cannot authenticate without an owned TLS session");
        try authenticator.putAuth(tls, self.options.configuration);
        _ = try self.sendAvailableCipherText(tls);
    }

    fn handleControlData(self: *Negotiator, data: []const u8) !void {
        const authenticator = if (self.authenticator) |*value| value else return;
        log.write(.info, "Pulled plain control data");
        authenticator.appendControlData(data);
        if (self.state == .auth) {
            if (!try authenticator.parseAuthReply()) return;
            if (self.isRenegotiating()) {
                self.setState(.connected);
                const history = if (self.history) |*value| value else {
                    @panic("Renegotiation completed without history from the original connection");
                };
                try self.completeConnection(history);
                return;
            }
            self.setState(.push);
            self.next_push_request_ns = core_mod.concurrency.deadlineAfterMs(
                core_mod.concurrency.monotonicNs(),
                self.options.session_options.retransmission_interval_ms,
            );
        }

        const messages = try authenticator.parseMessages(self.allocator);
        defer core_mod.util.freeSliceOfStrings(self.allocator, messages);
        for (messages) |message| {
            log.write(.info, "Parsed control message");
            self.handleControlMessage(message) catch |err| {
                self.options.on_error(
                    self.options.callback_context,
                    self.key,
                    errors_mod.sessionError(err),
                );
                return err;
            };
        }
    }

    fn handleControlMessage(self: *Negotiator, message: []const u8) !void {
        log.write(.info, "Received control message");
        if (std.mem.startsWith(u8, message, "AUTH_FAILED")) {
            const authenticator = self.authenticator orelse
                @panic("AUTH_FAILED received without an authenticator");
            if (authenticator.with_local_options) {
                log.write(.err, "Authentication failure, retry without local options");
                return error.BadCredentialsWithLocalOptions;
            }
            return error.BadCredentials;
        }
        if (std.mem.startsWith(u8, message, "RESTART")) {
            log.write(.info, "Disconnect due to server shutdown");
            return error.ServerShutdown;
        }
        if (self.state != .push) return;

        const complete_message = if (self.continued_push_reply_message) |previous|
            try std.mem.concat(self.allocator, u8, &.{ previous, ",", message })
        else
            try self.allocator.dupe(u8, message);
        defer self.allocator.free(complete_message);

        var reply = PushReply.parse(self.allocator, complete_message) catch |err| {
            if (err != error.ContinuationPushReply) return err;
            const stripped = try std.mem.replaceOwned(
                u8,
                self.allocator,
                complete_message,
                "push-continuation",
                "",
            );
            if (self.continued_push_reply_message) |old| self.allocator.free(old);
            self.continued_push_reply_message = stripped;
            return;
        } orelse return;
        defer reply.deinit(self.allocator);
        if (self.continued_push_reply_message) |old| self.allocator.free(old);
        self.continued_push_reply_message = null;

        log.writef(.info, "Received PUSH_REPLY: \"{s}\"", .{reply});

        if (reply.options.compression_framing) |framing| {
            const algorithm = reply.options.compression_algorithm orelse .disabled;
            if (algorithm != .disabled) {
                if (algorithm == .LZO) {
                    log.writef(.fault, "Server has LZO compression enabled and this was not built into the library (framing={s}): CompressionMismatch", .{
                        @tagName(framing),
                    });
                } else {
                    log.writef(.fault, "Server has compression enabled ({s}) and this is not supported (framing={s}): CompressionMismatch", .{
                        @tagName(algorithm),
                        @tagName(framing),
                    });
                }
                return error.CompressionMismatch;
            }
        }
        if (reply.options.ipv4 == null and reply.options.ipv6 == null)
            return error.NoRouting;
        self.setState(.connected);
        try self.completeConnection(&reply);
    }

    fn completeConnection(
        self: *Negotiator,
        push_reply: *const PushReply,
    ) !void {
        log.writef(.info, "Complete connection of key {d}", .{self.key});
        const data_channel = try self.newDataChannel(push_reply);
        errdefer data_channel.destroy();
        const history = try push_reply.clone(self.allocator);
        if (self.history) |*old| old.deinit(self.allocator);
        self.history = history;
        if (self.authenticator) |*authenticator| authenticator.reset();
        try self.options.on_connected(
            self.options.callback_context,
            self.key,
            data_channel,
            &self.history.?,
        );
    }

    fn newDataChannel(
        self: *const Negotiator,
        push_reply: *const PushReply,
    ) !*DataChannel {
        const session_id = self.channel.sessionId() orelse {
            @panic("Cannot create a data channel before the local session ID is established");
        };
        const remote_session_id = self.channel.remoteSessionId() orelse {
            @panic("Cannot create a data channel before the remote session ID is established");
        };
        const authenticator = if (self.authenticator) |*value| value else {
            @panic("Cannot create a data channel before authentication starts");
        };
        var handshake = authenticator.response() orelse {
            @panic("Cannot create a data channel before authentication produces a handshake");
        };
        defer handshake.deinit();

        log.write(.notice, "Set up encryption");
        const server_cipher = if (authenticator.server_options) |options|
            options.cipher
        else
            null;
        const parameters = DataPath.Parameters{
            .backend = self.options.session_options.backend,
            .cipher = configuration_mod.negotiatedDataChannelCipher(
                self.options.configuration,
                &push_reply.options,
                server_cipher,
            ),
            .digest = configuration_mod.fallbackDigest(self.options.configuration),
            .compression_framing = push_reply.options.compression_framing orelse
                configuration_mod.fallbackCompressionFraming(self.options.configuration),
            .peer_id = push_reply.options.peer_id,
        };
        var prf = try PRF.init(
            self.allocator,
            self.options.session_options.backend,
            &handshake,
            session_id,
            remote_session_id,
        );
        defer prf.deinit(self.allocator);
        const data_path = try DataPath.createWithPRF(
            self.allocator,
            parameters,
            &prf,
            self.prng,
        );
        errdefer data_path.destroy();
        return DataChannel.create(self.allocator, self.key, data_path);
    }

    fn wrappedKeyLength(self: *const Negotiator) usize {
        const wrapped = (self.options.configuration.tls_wrap orelse return 0)
            .wrapped_key orelse return 0;
        return std.base64.standard.Decoder.calcSizeForSlice(wrapped.base64) catch 0;
    }

    fn elapsedMs(self: *const Negotiator) u64 {
        const now = core_mod.concurrency.monotonicNs();
        if (now <= self.start_time_ns) return 0;
        return (now - self.start_time_ns) / std.time.ns_per_ms;
    }

    fn setState(self: *Negotiator, state: NegotiatorState) void {
        self.state = state;
        log.writef(.info, "Negotiator: {d} -> {s}", .{ self.key, @tagName(state) });
    }

    /// A lack of TLS output is expected while draining; actual TLS and control
    /// channel failures still propagate to the Session.
    fn sendAvailableCipherText(
        self: *Negotiator,
        tls: *TLSWrapper,
    ) !bool {
        const ciphertext = tls.pullCipherText(self.allocator) catch |err| {
            if (err == error.TLSFailure) {
                log.writef(.fault, "TLS: Failed pulling ciphertext: {s}", .{
                    @errorName(err),
                });
                return err;
            }
            log.write(.debug, "TLS: No available ciphertext to pull");
            return false;
        };
        defer self.allocator.free(ciphertext);
        log.write(.info, "TLS: Send pulled ciphertext");
        try self.enqueueControlPackets(.controlV1, ciphertext);
        return true;
    }
};

pub const testing = struct {
    pub const requestsWrappedKeyResend = Negotiator.requestsWrappedKeyResend;
};
