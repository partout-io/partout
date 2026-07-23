// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const net_mod = @import("../../net/exports.zig");
const auth_mod = @import("auth.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const control_mod = @import("control.zig");
const crypto_mod = @import("crypto.zig");
const data_mod = @import("data.zig");
const errors_mod = @import("errors.zig");
const helpers_mod = @import("helpers.zig");
const packet_mod = @import("packet.zig");
const processing_mod = @import("processing.zig");
const push_mod = @import("push.zig");
const serialization_mod = @import("serialization.zig");
const tls_mod = @import("tls.zig");

const api = core_mod.api;
const c_crypto = c_exports_mod.crypto;
const log = core_mod.logging;

const Authenticator = auth_mod.Authenticator;
const ConnectionOptions = configuration_mod.ConnectionOptions;
const ControlChannel = control_mod.ControlChannel(serialization_mod.Serializer);
const ControlConstants = constants_mod.Control;
const ControlPacket = packet_mod.ControlPacket;
const DataChannel = data_mod.DataChannel;
const DataPathParameters = data_mod.DataPathParameters;
const DataPathWrapper = data_mod.DataPathWrapper;
const LinkProcessor = processing_mod.LinkProcessor;
const PacketCode = packet_mod.PacketCode;
const PIAHardReset = crypto_mod.PIAHardReset;
const PRF = auth_mod.PRF;
const PRNG = crypto_mod.PRNG;
const PushReply = push_mod.PushReply;
const TLSWrapper = tls_mod.TLSWrapper;

/// Ordered phases of an OpenVPN key negotiation.
pub const RenegotiationType = enum {
    client,
    server,
};

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

pub const NegotiationHistory = struct {
    push_reply: PushReply,

    pub fn init(push_reply: *PushReply) NegotiationHistory {
        const moved = push_reply.*;
        push_reply.* = undefined;
        return .{ .push_reply = moved };
    }

    pub fn clone(
        self: NegotiationHistory,
        allocator: std.mem.Allocator,
    ) !NegotiationHistory {
        return .{ .push_reply = try self.push_reply.clone(allocator) };
    }

    pub fn deinit(self: *NegotiationHistory, allocator: std.mem.Allocator) void {
        self.push_reply.deinit(allocator);
        self.* = undefined;
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
    session_options: ConnectionOptions,
    callback_context: ?*anyopaque,
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
    fnt: c_crypto.pp_crypto_fnt,
    key: u8,
    history: ?NegotiationHistory,
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
    state: NegotiatorState = .idle,
    expected_packet_id: u32 = 0,
    pending_packets: std.AutoHashMap(u32, ControlPacket),
    authenticator: ?Authenticator = null,
    next_push_request_ns: ?u64 = null,
    continued_push_reply_message: ?[]u8 = null,
    should_resend_wrapped_key: bool = false,

    pub const Init = struct {
        fnt: c_crypto.pp_crypto_fnt,
        key: u8 = 0,
        history: ?NegotiationHistory = null,
        renegotiation: ?RenegotiationType = null,
        looper: *net_mod.Looper,
        link_processor: *LinkProcessor,
        remote_endpoint: *const api.ExtendedEndpoint,
        channel: *ControlChannel,
        prng: PRNG,
        tls: *TLSWrapper,
        options: NegotiatorOptions,
    };

    /// `tls` and `history` transfer only when creation succeeds.
    pub fn create(allocator: std.mem.Allocator, init: Init) !*Negotiator {
        const self = try allocator.create(Negotiator);
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
            .options = init.options,
            .start_time_ns = core_mod.concurrency.monotonicNs(),
            .negotiation_timeout_ms = if (init.renegotiation != null)
                init.options.session_options.soft_negotiation_timeout_ms
            else
                init.options.session_options.negotiation_timeout_ms,
            .pending_packets = std.AutoHashMap(u32, ControlPacket).init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *Negotiator) void {
        self.cancel();
        if (self.history) |*history| history.deinit(self.allocator);
        if (self.continued_push_reply_message) |message| self.allocator.free(message);
        if (self.tls) |tls| tls.destroy();
        self.pending_packets.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn forRenegotiation(
        self: *Negotiator,
        initiated_by: RenegotiationType,
    ) !*Negotiator {
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

    pub fn usesTLSCryptV2(self: *const Negotiator) bool {
        const wrap = self.options.configuration.tls_wrap orelse return false;
        return wrap.strategy == .cryptV2;
    }

    pub fn start(self: *Negotiator) !void {
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

    pub fn cancel(self: *Negotiator) void {
        var iterator = self.pending_packets.valueIterator();
        while (iterator.next()) |packet| packet.deinit();
        self.pending_packets.clearRetainingCapacity();
        if (self.authenticator) |*authenticator| authenticator.deinit();
        self.authenticator = null;
    }

    /// Performs the former recursive `Task.sleep` check once. The Session owns
    /// the stable timer and calls this method again when it returns `true`.
    pub fn tick(self: *Negotiator) !bool {
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
        return self.state != .connected;
    }

    pub fn readInboundPacket(
        self: *Negotiator,
        packet: []const u8,
        _: usize,
    ) !ControlPacket {
        // Preserve the V3 implementation's deliberate quirk: the public
        // offset parameter exists for parity, but channel parsing starts at 0.
        return self.channel.readInboundPacket(packet, 0);
    }

    /// Takes ownership of `packet`; the returned slice and packets are owned by
    /// the caller, as documented by ControlChannel.
    pub fn enqueueInboundPacket(
        self: *Negotiator,
        packet: ControlPacket,
    ) ![]ControlPacket {
        return self.channel.enqueueInboundPacket(packet);
    }

    pub fn handleControlPacket(
        self: *Negotiator,
        packet: *ControlPacket,
    ) !void {
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

    pub fn sendAck(self: *Negotiator, packet: *const ControlPacket) void {
        const raw = self.channel.writeAcks(
            packet.key(),
            &.{packet.packetId()},
            packet.sessionId(),
        ) catch |err| {
            self.options.on_error(
                self.options.callback_context,
                self.key,
                errors_mod.sessionError(err),
            );
            return;
        };
        defer self.allocator.free(raw);
        self.writeLink(&.{raw}) catch |err| {
            self.options.on_error(
                self.options.callback_context,
                self.key,
                errors_mod.sessionError(err),
            );
        };
    }

    pub fn shouldRenegotiate(self: *const Negotiator) bool {
        if (self.state != .connected) return false;
        const seconds = self.options.configuration.renegotiates_after orelse return false;
        if (seconds <= 0) return false;
        return self.elapsedMs() >= secondsToMilliseconds(seconds);
    }

    const EnqueueCipherText = *const fn (
        ?*anyopaque,
        []const u8,
    ) errors_mod.SessionError!void;

    fn hardResetPayload(self: *Negotiator) !?[]u8 {
        if (!(self.options.configuration.uses_pia_patches orelse false)) return null;
        const tls = self.tls orelse return error.Assertion;
        const ca_md5 = tls.caMD5(self.allocator) catch return null;
        defer self.allocator.free(ca_md5);
        return PIAHardReset.init(
            ca_md5,
            configuration_mod.fallbackCipher(self.options.configuration),
            configuration_mod.fallbackDigest(self.options.configuration),
        ).encodedData(self.allocator, self.prng) catch null;
    }

    fn pushRequest(self: *Negotiator) !void {
        if (self.state != .push) return;
        const next = self.next_push_request_ns orelse return;
        if (core_mod.concurrency.monotonicNs() <= next) return;
        const tls = self.tls orelse return error.Assertion;
        tls.putPlainText("PUSH_REQUEST\x00") catch {};
        const ciphertext = tls.pullCipherText(self.allocator) catch |err| {
            if (err == error.TLSFailure) return err;
            return;
        };
        defer self.allocator.free(ciphertext);
        try self.enqueueControlPackets(.controlV1, self.key, ciphertext);
        self.next_push_request_ns = deadlineAfter(
            self.options.session_options.push_request_interval_ms,
        );
    }

    fn enqueueControlPackets(
        self: *Negotiator,
        code: PacketCode,
        key: u8,
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
            key,
            payload,
            leading_limit,
            ControlConstants.max_payload_bytes_per_packet,
        );
        try self.flushControlQueue();
    }

    fn flushControlQueue(self: *Negotiator) !void {
        const raw_packets = try self.channel.writeOutboundPackets(
            @intCast(self.options.session_options.retransmission_interval_ms),
        );
        defer freePackets(self.allocator, raw_packets);
        if (raw_packets.len == 0) return;
        try self.writeLink(@ptrCast(raw_packets));
    }

    fn writeLink(self: *Negotiator, packets: []const []const u8) !void {
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
            if (value_type == ControlConstants.early_negotiation_flags_type and length >= 2) {
                const flags = std.mem.readInt(u16, bytes[offset..][0..2], .big);
                return flags & ControlConstants.early_negotiation_resend_wrapped_key != 0;
            }
            offset += length;
        }
        return false;
    }

    fn privateHandleControlPacket(
        self: *Negotiator,
        packet: *ControlPacket,
    ) !void {
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
                const tls = self.tls orelse return error.Assertion;
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
                const tls = self.tls orelse return error.Assertion;
                tls.putCipherText(payload) catch {};
                try self.forwardPulledCipherText(tls);

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

    fn onTLSConnect(self: *Negotiator) !void {
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
        const tls = self.tls orelse return error.Assertion;
        try self.authenticator.?.putAuth(tls, self.options.configuration);
        const ciphertext = tls.pullCipherText(self.allocator) catch |err| {
            if (err == error.TLSFailure) return err;
            return;
        };
        defer self.allocator.free(ciphertext);
        try self.enqueueControlPackets(.controlV1, self.key, ciphertext);
    }

    fn handleControlData(self: *Negotiator, data: []const u8) !void {
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
                if (algorithm != .disabled) return error.CompressionMismatch;
            }
        }
        if (reply.options.ipv4 == null and reply.options.ipv6 == null)
            return error.NoRouting;
        if (self.state == .connected) return;
        self.state = .connected;
        try self.completeConnection(&reply);
    }

    fn completeConnection(
        self: *Negotiator,
        push_reply: *const PushReply,
    ) !void {
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
        self: *Negotiator,
        push_reply: *const PushReply,
    ) !*DataChannel {
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
            .cipher = configuration_mod.negotiatedDataChannelCipher(
                self.options.configuration,
                &push_reply.options,
                server_cipher,
            ),
            .digest = configuration_mod.fallbackDigest(self.options.configuration),
            .compression_framing = push_reply.options.compression_framing orelse
                configuration_mod.fallbackCompressionFraming(self.options.configuration),
            .compression_algorithm = push_reply.options.compression_algorithm orelse
                configuration_mod.fallbackCompressionAlgorithm(self.options.configuration),
            .peer_id = push_reply.options.peer_id,
        };
        var prf = try PRF.init(
            self.allocator,
            self.fnt,
            &handshake,
            session_id,
            remote_session_id,
        );
        defer prf.deinit(self.allocator);
        var data_path = try DataPathWrapper.createWithPRF(
            self.allocator,
            parameters,
            &prf,
            self.prng,
        );
        errdefer data_path.deinit();
        return DataChannel.create(self.allocator, self.key, data_path);
    }

    fn wrappedKeyLength(self: *const Negotiator) usize {
        const wrapped = (self.options.configuration.tls_wrap orelse return 0)
            .wrapped_key orelse return 0;
        return std.base64.standard.Decoder.calcSizeForSlice(wrapped.base64) catch 0;
    }

    fn elapsedMs(self: *const Negotiator) u64 {
        return (core_mod.concurrency.monotonicNs() -| self.start_time_ns) /
            std.time.ns_per_ms;
    }

    fn deadlineAfter(delay_ms: u64) u64 {
        return core_mod.concurrency.monotonicNs() +|
            delay_ms *| @as(u64, std.time.ns_per_ms);
    }

    fn secondsToMilliseconds(seconds: f64) u64 {
        if (!(seconds > 0)) return 0;
        const milliseconds = seconds * 1000.0;
        if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            return std.math.maxInt(u64);
        return @intFromFloat(milliseconds);
    }

    /// Pull absence/non-native pull failures are non-fatal during TLS drain,
    /// but a successful pull transfers control to the normal outbound path;
    /// failures from that path must propagate to the Session.
    fn forwardPulledCipherText(
        self: *Negotiator,
        tls: *TLSWrapper,
    ) !void {
        const ciphertext = tls.pullCipherText(self.allocator) catch |err| {
            if (err == error.TLSFailure) return err;
            return;
        };
        try forwardCipherText(
            self.allocator,
            ciphertext,
            self,
            enqueuePulledCipherText,
        );
    }

    fn forwardCipherText(
        allocator: std.mem.Allocator,
        ciphertext: []u8,
        context: ?*anyopaque,
        enqueue: EnqueueCipherText,
    ) !void {
        defer allocator.free(ciphertext);
        try enqueue(context, ciphertext);
    }

    fn enqueuePulledCipherText(
        raw: ?*anyopaque,
        ciphertext: []const u8,
    ) !void {
        const self: *Negotiator = @ptrCast(@alignCast(raw.?));
        self.enqueueControlPackets(.controlV1, self.key, ciphertext) catch |err| {
            return errors_mod.sessionError(err);
        };
    }

    fn freePackets(allocator: std.mem.Allocator, packets: [][]u8) void {
        for (packets) |packet| allocator.free(packet);
        allocator.free(packets);
    }

    fn removeAllAlloc(
        allocator: std.mem.Allocator,
        input: []const u8,
        needle: []const u8,
    ) ![]u8 {
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

pub const testing = struct {
    pub fn forwardCipherText(
        allocator: std.mem.Allocator,
        ciphertext: []u8,
        context: ?*anyopaque,
        enqueue: Negotiator.EnqueueCipherText,
    ) !void {
        return Negotiator.forwardCipherText(allocator, ciphertext, context, enqueue);
    }

    pub fn requestsWrappedKeyResend(payload: ?[]const u8) bool {
        return Negotiator.requestsWrappedKeyResend(payload);
    }
};
