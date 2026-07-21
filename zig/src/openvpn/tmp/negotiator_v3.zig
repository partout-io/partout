// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const net = @import("../../net/exports.zig");
const Authenticator = @import("authenticator.zig").Authenticator;
const CControlPacket = @import("c_control_packet.zig").CControlPacket;
const CPacketCode = @import("c_packet_code.zig").CPacketCode;
const configuration_helpers = @import("configuration_helpers.zig");
const ControlChannelV3 = @import("control_channel_v3.zig").ControlChannelV3;
const ControlChannelConstants = @import("control_channel_constants.zig").ControlChannel;
const CryptoKeysPRF = @import("crypto_keys_prf.zig").CryptoKeysPRF;
const DataChannel = @import("data_channel.zig").DataChannel;
const DataPathFactory = @import("factories.zig").DataPathFactory;
const DataPathParameters = @import("data_path_parameters.zig").DataPathParameters;
const LinkProcessor = @import("link_processor.zig").LinkProcessor;
const NegotiationHistory = @import("negotiation_history.zig").NegotiationHistory;
const NegotiatorOptions = @import("negotiator_options.zig").NegotiatorOptions;
const NegotiatorState = @import("negotiator_state.zig").NegotiatorState;
const PIAHardReset = @import("pia_hard_reset.zig").PIAHardReset;
const PRNG = @import("prng.zig").PRNG;
const PushReply = @import("push_reply.zig").PushReply;
const RenegotiationType = @import("renegotiation_type.zig").RenegotiationType;
const TLSProtocol = @import("tls_protocol.zig").TLSProtocol;
const c = @import("c.zig").api;

const api = core.api;

/// V3 control-channel state machine. All mutable methods run on `looper`.
pub const NegotiatorV3 = struct {
    allocator: std.mem.Allocator,
    fnt: c.pp_crypto_fnt,
    key: u8,
    history: ?NegotiationHistory,
    renegotiation: ?RenegotiationType,
    looper: *net.Looper,
    link_processor: *LinkProcessor,
    remote_endpoint: *const api.ExtendedEndpoint,
    channel: *ControlChannelV3,
    prng: PRNG,
    tls: ?TLSProtocol,
    data_path_factory: DataPathFactory,
    options: NegotiatorOptions,

    start_time_ns: u64,
    negotiation_timeout_ms: u64,
    state: NegotiatorState = .idle,
    expected_packet_id: u32 = 0,
    pending_packets: std.AutoHashMap(u32, CControlPacket),
    authenticator: ?Authenticator = null,
    next_push_request_ns: ?u64 = null,
    continued_push_reply_message: ?[]u8 = null,
    should_resend_wrapped_key: bool = false,

    pub const Init = struct {
        fnt: c.pp_crypto_fnt,
        key: u8 = 0,
        history: ?NegotiationHistory = null,
        renegotiation: ?RenegotiationType = null,
        looper: *net.Looper,
        link_processor: *LinkProcessor,
        remote_endpoint: *const api.ExtendedEndpoint,
        channel: *ControlChannelV3,
        prng: PRNG,
        tls: TLSProtocol,
        data_path_factory: DataPathFactory,
        options: NegotiatorOptions,
    };

    /// `tls` and `history` transfer only when creation succeeds.
    pub fn create(allocator: std.mem.Allocator, init: Init) std.mem.Allocator.Error!*NegotiatorV3 {
        const self = try allocator.create(NegotiatorV3);
        self.* = .{
            .allocator = allocator,
            .fnt = init.fnt,
            .key = init.key,
            .history = init.history,
            .renegotiation = init.renegotiation,
            .looper = init.looper,
            .link_processor = init.link_processor,
            .remote_endpoint = init.remote_endpoint,
            .channel = init.channel,
            .prng = init.prng,
            .tls = init.tls,
            .data_path_factory = init.data_path_factory,
            .options = init.options,
            .start_time_ns = core.concurrency.monotonicNs(),
            .negotiation_timeout_ms = if (init.renegotiation != null)
                init.options.session_options.soft_negotiation_timeout_ms
            else
                init.options.session_options.negotiation_timeout_ms,
            .pending_packets = std.AutoHashMap(u32, CControlPacket).init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *NegotiatorV3) void {
        self.cancel();
        if (self.history) |*history| history.deinit(self.allocator);
        if (self.continued_push_reply_message) |message| self.allocator.free(message);
        if (self.tls) |*tls| tls.deinit();
        self.pending_packets.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn forRenegotiation(
        self: *NegotiatorV3,
        initiated_by: RenegotiationType,
    ) anyerror!*NegotiatorV3 {
        const history = if (self.history) |value|
            try value.clone(self.allocator)
        else
            // The Swift implementation deliberately keeps using the current
            // negotiator when a premature SOFT_RESET arrives before history
            // exists.
            return self;
        errdefer {
            var mutable = history;
            mutable.deinit(self.allocator);
        }

        const tls = self.tls orelse return error.Assertion;
        self.tls = null;
        errdefer self.tls = tls;
        return create(self.allocator, .{
            .fnt = self.fnt,
            .key = ControlChannelConstants.nextKey(self.key),
            .history = history,
            .renegotiation = initiated_by,
            .looper = self.looper,
            .link_processor = self.link_processor,
            .remote_endpoint = self.remote_endpoint,
            .channel = self.channel,
            .prng = self.prng,
            .tls = tls,
            .data_path_factory = self.data_path_factory,
            .options = self.options,
        });
    }

    pub fn isConnected(self: *const NegotiatorV3) bool {
        return self.state == .connected;
    }

    pub fn isRenegotiating(self: *const NegotiatorV3) bool {
        return self.renegotiation != null and self.state != .connected;
    }

    pub fn usesTLSCryptV2(self: *const NegotiatorV3) bool {
        const wrap = self.options.configuration.tls_wrap orelse return false;
        return wrap.strategy == .cryptV2;
    }

    pub fn start(self: *NegotiatorV3) anyerror!void {
        std.debug.assert(self.looper.isOnQueue());
        try self.channel.reset(self.renegotiation == null);
        _ = try self.tick();

        if (self.renegotiation) |kind| switch (kind) {
            .client => try self.enqueueControlPackets(.softResetV1, self.key, ""),
            .server => {},
        } else {
            const hard_reset_payload = try self.hardResetPayload();
            defer if (hard_reset_payload) |payload| self.allocator.free(payload);
            try self.enqueueControlPackets(
                if (self.usesTLSCryptV2()) .hardResetClientV3 else .hardResetClientV2,
                self.key,
                hard_reset_payload orelse "",
            );
        }
    }

    pub fn cancel(self: *NegotiatorV3) void {
        var iterator = self.pending_packets.valueIterator();
        while (iterator.next()) |packet| packet.deinit();
        self.pending_packets.clearRetainingCapacity();
        if (self.authenticator) |*authenticator| authenticator.deinit();
        self.authenticator = null;
    }

    /// Performs the former recursive `Task.sleep` check once. The Session owns
    /// the stable timer and calls this method again when it returns `true`.
    pub fn tick(self: *NegotiatorV3) anyerror!bool {
        std.debug.assert(self.looper.isOnQueue());
        const elapsed = self.elapsedMs();
        if (self.state == .idle and elapsed > self.options.session_options.hard_reset_timeout_ms)
            return error.Recoverable;
        if (self.state != .connected and elapsed > self.negotiation_timeout_ms)
            return error.NegotiationTimeout;

        if (!self.isRenegotiating()) try self.pushRequest();
        if (self.remote_endpoint.plainSocketType() == .udp) try self.flushControlQueue();
        return self.state != .connected;
    }

    pub fn readInboundPacket(
        self: *NegotiatorV3,
        packet: []const u8,
        _: usize,
    ) anyerror!CControlPacket {
        // Preserve the V3 implementation's deliberate quirk: the public
        // offset parameter exists for parity, but channel parsing starts at 0.
        return self.channel.readInboundPacket(packet, 0);
    }

    /// Takes ownership of `packet`; the returned slice and packets are owned by
    /// the caller, as documented by ControlChannelV3.
    pub fn enqueueInboundPacket(
        self: *NegotiatorV3,
        packet: CControlPacket,
    ) anyerror![]CControlPacket {
        return self.channel.enqueueInboundPacket(packet);
    }

    pub fn handleControlPacket(
        self: *NegotiatorV3,
        packet: *CControlPacket,
    ) anyerror!void {
        const packet_id = packet.packetId();
        if (packet_id < self.expected_packet_id) return;
        if (packet_id > self.expected_packet_id) {
            const owned = packet.move();
            errdefer {
                var mutable = owned;
                mutable.deinit();
            }
            if (try self.pending_packets.fetchPut(packet_id, owned)) |old| {
                var replaced = old.value;
                replaced.deinit();
            }
            return;
        }

        try self.privateHandleControlPacket(packet);
        self.expected_packet_id +%= 1;
        while (self.pending_packets.fetchRemove(self.expected_packet_id)) |entry| {
            var pending = entry.value;
            defer pending.deinit();
            try self.privateHandleControlPacket(&pending);
            self.expected_packet_id +%= 1;
        }
    }

    pub fn handleAcks(_: *NegotiatorV3) void {}

    pub fn sendAck(self: *NegotiatorV3, packet: *const CControlPacket) void {
        const raw = self.channel.writeAcks(
            packet.key(),
            &.{packet.packetId()},
            packet.sessionId(),
        ) catch |err| {
            self.options.on_error(self.options.callback_context, self.key, err);
            return;
        };
        defer self.allocator.free(raw);
        self.writeLink(&.{raw}) catch |err| {
            self.options.on_error(self.options.callback_context, self.key, err);
        };
    }

    pub fn shouldRenegotiate(self: *const NegotiatorV3) bool {
        if (self.state != .connected) return false;
        const seconds = self.options.configuration.renegotiates_after orelse return false;
        if (seconds <= 0) return false;
        return self.elapsedMs() >= secondsToMilliseconds(seconds);
    }

    fn hardResetPayload(self: *NegotiatorV3) anyerror!?[]u8 {
        if (!(self.options.configuration.uses_pia_patches orelse false)) return null;
        const tls = self.tls orelse return error.Assertion;
        const ca_md5 = tls.caMD5(self.allocator) catch return null;
        defer self.allocator.free(ca_md5);
        return PIAHardReset.init(
            ca_md5,
            configuration_helpers.fallbackCipher(self.options.configuration.*),
            configuration_helpers.fallbackDigest(self.options.configuration.*),
        ).encodedData(self.allocator, self.prng) catch null;
    }

    fn pushRequest(self: *NegotiatorV3) anyerror!void {
        if (self.state != .push) return;
        const next = self.next_push_request_ns orelse return;
        if (core.concurrency.monotonicNs() <= next) return;
        const tls = self.tls orelse return error.Assertion;
        tls.putPlainText("PUSH_REQUEST\x00") catch {};
        const ciphertext = tls.pullCipherText(self.allocator) catch |err| {
            if (isNativeTLSError(err)) return err;
            return;
        };
        defer self.allocator.free(ciphertext);
        try self.enqueueControlPackets(.controlV1, self.key, ciphertext);
        self.next_push_request_ns = deadlineAfter(
            self.options.session_options.push_request_interval_ms,
        );
    }

    fn enqueueControlPackets(
        self: *NegotiatorV3,
        code: CPacketCode,
        key: u8,
        payload: []const u8,
    ) anyerror!void {
        var leading_code = code;
        var leading_limit = ControlChannelConstants.max_payload_bytes_per_packet;
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
            key,
            payload,
            leading_limit,
            ControlChannelConstants.max_payload_bytes_per_packet,
        );
        try self.flushControlQueue();
    }

    fn flushControlQueue(self: *NegotiatorV3) anyerror!void {
        const raw_packets = try self.channel.writeOutboundPackets(
            @intCast(self.options.session_options.retransmission_interval_ms),
        );
        defer freePackets(self.allocator, raw_packets);
        if (raw_packets.len == 0) return;
        try self.writeLink(@ptrCast(raw_packets));
    }

    fn writeLink(self: *NegotiatorV3, packets: []const []const u8) anyerror!void {
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
            if (offset + length > bytes.len) return false;
            if (value_type == ControlChannelConstants.early_negotiation_flags_type and length >= 2) {
                const flags = std.mem.readInt(u16, bytes[offset..][0..2], .big);
                return flags & ControlChannelConstants.early_negotiation_resend_wrapped_key != 0;
            }
            offset += length;
        }
        return false;
    }

    fn privateHandleControlPacket(
        self: *NegotiatorV3,
        packet: *CControlPacket,
    ) anyerror!void {
        if (packet.key() != self.key) return;
        switch (self.state) {
            .idle => {
                if (packet.code != .hardResetServerV2 and packet.code != .softResetV1) return;
                if (packet.code == .hardResetServerV2) {
                    try self.channel.setRemoteSessionId(packet.sessionId());
                    self.should_resend_wrapped_key = self.usesTLSCryptV2() and
                        requestsWrappedKeyResend(packet.payload());
                }
                const remote_session_id = self.channel.remoteSessionId() orelse
                    return error.MissingSessionId;
                if (!std.mem.eql(u8, packet.sessionId(), remote_session_id))
                    return error.SessionMismatch;

                self.state = .tls;
                const tls = if (self.tls) |*value| value else return error.Assertion;
                try tls.start();
                const ciphertext = try tls.pullCipherText(self.allocator);
                defer self.allocator.free(ciphertext);
                try self.enqueueControlPackets(.controlV1, self.key, ciphertext);
            },
            .tls, .auth, .push, .connected => {
                if (packet.code != .controlV1) return;
                const remote_session_id = self.channel.remoteSessionId() orelse
                    return error.MissingSessionId;
                if (!std.mem.eql(u8, packet.sessionId(), remote_session_id))
                    return error.SessionMismatch;
                const payload = packet.payload() orelse return;
                const tls = if (self.tls) |*value| value else return error.Assertion;
                tls.putCipherText(payload) catch {};
                try forwardPulledCipherText(
                    self.allocator,
                    tls.*,
                    self,
                    enqueuePulledCipherText,
                );

                if (self.state.before(.auth) and tls.isConnected()) {
                    self.state = .auth;
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

    fn onTLSConnect(self: *NegotiatorV3) anyerror!void {
        const credentials = self.options.credentials;
        const username = if (credentials) |value| value.username else null;
        const password = if (self.history) |*history|
            history.push_reply.options.auth_token orelse
                (if (credentials) |value| value.password else null)
        else if (credentials) |value|
            value.password
        else
            null;
        if (self.authenticator) |*old| old.deinit();
        self.authenticator = try Authenticator.init(
            self.allocator,
            self.prng,
            username,
            password,
        );
        self.authenticator.?.with_local_options = self.options.with_local_options;
        const tls = if (self.tls) |*value| value else return error.Assertion;
        try self.authenticator.?.putAuth(tls.*, self.options.configuration.*);
        const ciphertext = tls.pullCipherText(self.allocator) catch |err| {
            if (isNativeTLSError(err)) return err;
            return;
        };
        defer self.allocator.free(ciphertext);
        try self.enqueueControlPackets(.controlV1, self.key, ciphertext);
    }

    fn handleControlData(self: *NegotiatorV3, data: []const u8) anyerror!void {
        const authenticator = if (self.authenticator) |*value| value else return;
        try authenticator.appendControlData(data);
        if (self.state == .auth) {
            if (!try authenticator.parseAuthReply()) return;
            if (self.isRenegotiating()) {
                self.state = .connected;
                const history = if (self.history) |*value| value else return error.Assertion;
                try self.completeConnection(&history.push_reply);
                return;
            }
            self.state = .push;
            self.next_push_request_ns = deadlineAfter(
                self.options.session_options.retransmission_interval_ms,
            );
        }

        const messages = try authenticator.parseMessages(self.allocator);
        defer freePackets(self.allocator, messages);
        for (messages) |message| {
            self.handleControlMessage(message) catch |err| {
                self.options.on_error(self.options.callback_context, self.key, err);
                return err;
            };
        }
    }

    fn handleControlMessage(self: *NegotiatorV3, message: []const u8) anyerror!void {
        if (std.mem.startsWith(u8, message, "AUTH_FAILED")) {
            if (self.authenticator.?.with_local_options)
                return error.BadCredentialsWithLocalOptions;
            return error.BadCredentials;
        }
        if (std.mem.startsWith(u8, message, "RESTART")) return error.ServerShutdown;
        if (self.state != .push) return;

        const complete_message = if (self.continued_push_reply_message) |previous|
            try std.mem.concat(self.allocator, u8, &.{ previous, ",", message })
        else
            try self.allocator.dupe(u8, message);
        defer self.allocator.free(complete_message);

        var reply = PushReply.parse(self.allocator, complete_message) catch |err| {
            if (err != error.ContinuationPushReply) return err;
            const stripped = try removeAllAlloc(
                self.allocator,
                complete_message,
                "push-continuation",
            );
            if (self.continued_push_reply_message) |old| self.allocator.free(old);
            self.continued_push_reply_message = stripped;
            return;
        } orelse return;
        defer reply.deinit(self.allocator);
        if (self.continued_push_reply_message) |old| self.allocator.free(old);
        self.continued_push_reply_message = null;

        if (reply.options.compression_framing != null) {
            if (reply.options.compression_algorithm) |algorithm| {
                if (algorithm != .disabled) return error.ServerCompression;
            }
        }
        if (reply.options.ipv4 == null and reply.options.ipv6 == null)
            return error.NoRouting;
        if (self.state == .connected) return;
        self.state = .connected;
        try self.completeConnection(&reply);
    }

    fn completeConnection(
        self: *NegotiatorV3,
        push_reply: *const PushReply,
    ) anyerror!void {
        const data_channel = try self.newDataChannel(push_reply);
        errdefer data_channel.destroy();
        var reply_copy = try push_reply.clone(self.allocator);
        var reply_transferred = false;
        errdefer if (!reply_transferred) reply_copy.deinit(self.allocator);
        var history = NegotiationHistory.init(&reply_copy);
        reply_transferred = true;
        var history_transferred = false;
        errdefer if (!history_transferred) history.deinit(self.allocator);
        if (self.history) |*old| old.deinit(self.allocator);
        self.history = history;
        history_transferred = true;
        if (self.authenticator) |*authenticator| authenticator.reset();
        try self.options.on_connected(
            self.options.callback_context,
            self.key,
            data_channel,
            &self.history.?.push_reply,
        );
    }

    fn newDataChannel(
        self: *NegotiatorV3,
        push_reply: *const PushReply,
    ) anyerror!*DataChannel {
        const session_id = self.channel.sessionId() orelse return error.Assertion;
        const remote_session_id = self.channel.remoteSessionId() orelse return error.Assertion;
        const authenticator = if (self.authenticator) |*value| value else return error.Assertion;
        var handshake = (try authenticator.response(self.allocator)) orelse return error.Assertion;
        defer handshake.deinit(self.allocator);

        const server_cipher = if (authenticator.server_options) |options|
            options.cipher
        else
            null;
        const parameters = DataPathParameters{
            .fnt = self.fnt.enc,
            .cipher = configuration_helpers.negotiatedDataChannelCipher(
                self.options.configuration.*,
                push_reply.options,
                server_cipher,
            ),
            .digest = configuration_helpers.fallbackDigest(self.options.configuration.*),
            .compression_framing = push_reply.options.compression_framing orelse
                configuration_helpers.fallbackCompressionFraming(self.options.configuration.*),
            .compression_algorithm = push_reply.options.compression_algorithm orelse
                configuration_helpers.fallbackCompressionAlgorithm(self.options.configuration.*),
            .peer_id = push_reply.options.peer_id,
        };
        var prf = try CryptoKeysPRF.init(
            self.allocator,
            self.fnt,
            &handshake,
            session_id,
            remote_session_id,
        );
        defer prf.deinit(self.allocator);
        var data_path = try self.data_path_factory(
            self.allocator,
            parameters,
            prf.move(),
            self.prng,
        );
        errdefer data_path.deinit();
        return DataChannel.create(self.allocator, self.key, data_path);
    }

    fn wrappedKeyLength(self: *const NegotiatorV3) usize {
        const wrapped = (self.options.configuration.tls_wrap orelse return 0)
            .wrapped_key orelse return 0;
        return std.base64.standard.Decoder.calcSizeForSlice(wrapped.base64) catch 0;
    }

    fn elapsedMs(self: *const NegotiatorV3) u64 {
        return (core.concurrency.monotonicNs() -| self.start_time_ns) /
            std.time.ns_per_ms;
    }

    fn deadlineAfter(delay_ms: u64) u64 {
        return core.concurrency.monotonicNs() +|
            delay_ms *| @as(u64, std.time.ns_per_ms);
    }

    fn secondsToMilliseconds(seconds: f64) u64 {
        if (!(seconds > 0)) return 0;
        const milliseconds = seconds * 1000.0;
        if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            return std.math.maxInt(u64);
        return @intFromFloat(milliseconds);
    }

    fn isNativeTLSError(err: anyerror) bool {
        return switch (err) {
            error.TLSCARead,
            error.TLSCAUse,
            error.TLSCAPeerVerification,
            error.TLSClientCertificateRead,
            error.TLSClientCertificateUse,
            error.TLSClientKeyRead,
            error.TLSClientKeyUse,
            error.TLSHandshake,
            error.TLSServerEKU,
            error.TLSServerHost,
            error.TLSFailure,
            => true,
            else => false,
        };
    }

    /// Pull absence/non-native pull failures are non-fatal during TLS drain,
    /// but a successful pull transfers control to the normal outbound path;
    /// failures from that path must propagate to the Session.
    fn forwardPulledCipherText(
        allocator: std.mem.Allocator,
        tls: TLSProtocol,
        context: ?*anyopaque,
        enqueue: *const fn (?*anyopaque, []const u8) anyerror!void,
    ) anyerror!void {
        const ciphertext = tls.pullCipherText(allocator) catch |err| {
            if (isNativeTLSError(err)) return err;
            return;
        };
        defer allocator.free(ciphertext);
        try enqueue(context, ciphertext);
    }

    fn enqueuePulledCipherText(raw: ?*anyopaque, ciphertext: []const u8) anyerror!void {
        const self: *NegotiatorV3 = @ptrCast(@alignCast(raw.?));
        try self.enqueueControlPackets(.controlV1, self.key, ciphertext);
    }

    fn freePackets(allocator: std.mem.Allocator, packets: [][]u8) void {
        for (packets) |packet| allocator.free(packet);
        allocator.free(packets);
    }

    fn removeAllAlloc(
        allocator: std.mem.Allocator,
        input: []const u8,
        needle: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        if (needle.len == 0) return allocator.dupe(u8, input);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var remaining = input;
        while (std.mem.indexOf(u8, remaining, needle)) |index| {
            output.writer.writeAll(remaining[0..index]) catch return error.OutOfMemory;
            remaining = remaining[index + needle.len ..];
        }
        output.writer.writeAll(remaining) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }
};

test "NegotiatorV3 declarations are semantically analyzed" {
    std.testing.refAllDecls(NegotiatorV3);
}

test "early-negotiation TLV requests wrapped-key resend" {
    const payload = [_]u8{
        0x00, 0x01, // early-negotiation flags
        0x00, 0x02, // two-byte flags payload
        0x00, 0x01, // resend wrapped key
    };
    try std.testing.expect(NegotiatorV3.requestsWrappedKeyResend(&payload));
    try std.testing.expect(!NegotiatorV3.requestsWrappedKeyResend(payload[0..5]));
}

test "successful TLS pull propagates control enqueue failure" {
    const Fake = struct {
        fn start(_: *anyopaque) anyerror!void {}
        fn isConnected(_: *anyopaque) bool {
            return true;
        }
        fn put(_: *anyopaque, _: []const u8) anyerror!void {}
        fn pullPlain(_: *anyopaque, _: std.mem.Allocator) anyerror![]u8 {
            return error.TLSNoData;
        }
        fn pullCipher(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "ciphertext");
        }
        fn caMD5(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.alloc(u8, 0);
        }
        fn deinit(_: *anyopaque) void {}
        fn failEnqueue(_: ?*anyopaque, _: []const u8) anyerror!void {
            return error.ControlChannelFailure;
        }

        const vtable = TLSProtocol.VTable{
            .start = start,
            .is_connected = isConnected,
            .put_plain_text = put,
            .put_raw_plain_text = put,
            .put_cipher_text = put,
            .pull_plain_text = pullPlain,
            .pull_cipher_text = pullCipher,
            .ca_md5 = caMD5,
            .deinit = deinit,
        };
    };

    var fake_context: u8 = 0;
    const tls = TLSProtocol{ .ptr = &fake_context, .vtable = &Fake.vtable };
    try std.testing.expectError(
        error.ControlChannelFailure,
        NegotiatorV3.forwardPulledCipherText(
            std.testing.allocator,
            tls,
            null,
            Fake.failEnqueue,
        ),
    );
}
