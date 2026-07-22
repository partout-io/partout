// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const c_crypto = @import("../../c/exports.zig").crypto;
const c = @import("c.zig").api;
const helpers = @import("helpers.zig");
const BidirectionalState = helpers.BidirectionalState;
const control = @import("control.zig");
const packet_types = @import("packet.zig");
const ControlPacket = packet_types.ControlPacket;
const PacketCode = packet_types.PacketCode;
const ControlConstants = @import("constants.zig").Control;
const crypto = @import("crypto.zig");
const CryptoKeysBridge = crypto.CryptoKeysBridge;
const errors = @import("errors.zig");
const configuration_helpers = @import("configuration.zig");
const PRNG = crypto.PRNG;
const static_key = helpers;
const time = helpers;

const api = core.api;

/// Concrete serializer variants selected once when a control channel is built.
pub const Serializer = union(enum) {
    plain: PlainSerializer,
    auth: AuthSerializer,
    crypt: CryptSerializer,
    crypt_v2: CryptV2Serializer,

    pub fn forConfiguration(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_enc_fnt,
        configuration: *const api.OpenVPNConfiguration,
    ) anyerror!Serializer {
        if (configuration.tls_wrap) |wrap| {
            return switch (wrap.strategy) {
                .auth => .{ .auth = try AuthSerializer.init(
                    allocator,
                    fnt,
                    configuration_helpers.fallbackDigest(configuration.*),
                    wrap.key,
                ) },
                .crypt => .{ .crypt = try CryptSerializer.init(allocator, fnt, wrap.key) },
                .cryptV2 => .{ .crypt_v2 = try CryptV2Serializer.init(
                    allocator,
                    fnt,
                    wrap.key,
                    wrap.wrapped_key orelse return error.Assertion,
                ) },
            };
        }
        return .{ .plain = .{} };
    }

    pub fn deinit(self: *Serializer, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .plain => {},
            .auth => |*value| value.deinit(),
            .crypt => |*value| value.deinit(),
            .crypt_v2 => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn reset(self: *Serializer) void {
        switch (self.*) {
            inline else => |*value| value.reset(),
        }
    }

    pub fn serialize(
        self: *Serializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
    ) anyerror![]u8 {
        return switch (self.*) {
            inline else => |*value| value.serialize(allocator, packet),
        };
    }

    pub fn deserialize(
        self: *Serializer,
        allocator: std.mem.Allocator,
        data: []const u8,
        start: usize,
        end: ?usize,
    ) anyerror!ControlPacket {
        return switch (self.*) {
            inline else => |*value| value.deserialize(allocator, data, start, end),
        };
    }
};

pub const PlainSerializer = struct {
    pub const ParseError = errors.PlainSerializerError;

    pub fn reset(_: *PlainSerializer) void {}

    pub fn serialize(
        _: *PlainSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
    ) std.mem.Allocator.Error![]u8 {
        return packet.serializedAlloc(allocator);
    }

    pub fn deserialize(
        _: *PlainSerializer,
        _: std.mem.Allocator,
        data: []const u8,
        start: usize,
        optional_end: ?usize,
    ) (ParseError || ControlPacket.InitError)!ControlPacket {
        const end = optional_end orelse data.len;
        if (start > end or end > data.len) return error.InvalidRange;
        var offset = start;

        if (end - offset < c.OpenVPNPacketOpcodeLength) return error.MissingOpcode;
        const code = PacketCode.fromRaw(data[offset] >> 3) orelse return error.UnknownCode;
        const key = data[offset] & 0b111;
        offset += c.OpenVPNPacketOpcodeLength;

        if (end - offset < c.OpenVPNPacketSessionIdLength) return error.MissingSessionId;
        const session_id = data[offset .. offset + c.OpenVPNPacketSessionIdLength];
        offset += c.OpenVPNPacketSessionIdLength;

        if (end - offset < c.OpenVPNPacketAckLengthLength) return error.MissingAckSize;
        const ack_count: usize = data[offset];
        offset += c.OpenVPNPacketAckLengthLength;

        var ack_storage: [std.math.maxInt(u8)]u32 = undefined;
        var ack_ids: ?[]const u32 = null;
        var remote_session_id: ?[]const u8 = null;
        if (ack_count > 0) {
            const ack_bytes = ack_count * c.OpenVPNPacketIdLength;
            if (end - offset < ack_bytes) return error.MissingAcks;
            for (ack_storage[0..ack_count]) |*ack_id| {
                ack_id.* = std.mem.readInt(u32, data[offset..][0..4], .big);
                offset += c.OpenVPNPacketIdLength;
            }
            ack_ids = ack_storage[0..ack_count];

            if (end - offset < c.OpenVPNPacketSessionIdLength) return error.MissingRemoteSessionId;
            remote_session_id = data[offset .. offset + c.OpenVPNPacketSessionIdLength];
            offset += c.OpenVPNPacketSessionIdLength;
        }

        if (code == .ackV1) {
            const ids = ack_ids orelse return error.AckPacketWithoutIds;
            const remote = remote_session_id orelse return error.AckPacketWithoutRemoteSessionId;
            return ControlPacket.initAck(key, session_id, ids, remote);
        }

        if (end - offset < c.OpenVPNPacketIdLength) return error.MissingPacketId;
        const packet_id = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += c.OpenVPNPacketIdLength;
        const payload: ?[]const u8 = if (offset < end) data[offset..end] else null;
        return ControlPacket.init(code, key, session_id, packet_id, payload, ack_ids, remote_session_id);
    }
};

pub const AuthSerializer = struct {
    fnt: c_crypto.pp_crypto_enc_fnt,
    cbc: c_crypto.pp_crypto_ctx,
    prefix_length: usize,
    hmac_length: usize,
    auth_length: usize,
    preamble_length: usize,
    current_replay_id: BidirectionalState(u32),
    timestamp: u32,
    plain: PlainSerializer = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_enc_fnt,
        digest: api.OpenVPNDigest,
        key: api.OpenVPNStaticKey,
    ) anyerror!AuthSerializer {
        var keys = try static_key.authKeys(allocator, key);
        defer keys.deinit(allocator);
        var bridge = try CryptoKeysBridge.init(allocator, &keys);
        defer bridge.deinit();
        var digest_name: core.util.TemporaryCString = .{};
        try digest_name.init(allocator, digest.raw());
        defer digest_name.deinit();
        const cbc = fnt.cbc_create.?(null, digest_name.ptr(), bridge.native()) orelse return error.UnsupportedAlgorithm;
        const prefix_length = c.OpenVPNPacketOpcodeLength + c.OpenVPNPacketSessionIdLength;
        const hmac_length = c_crypto.pp_crypto_meta_of(cbc).digest_len;
        const auth_length = hmac_length + c.OpenVPNPacketReplayIdLength + c.OpenVPNPacketReplayTimestampLength;
        return .{
            .fnt = fnt,
            .cbc = cbc,
            .prefix_length = prefix_length,
            .hmac_length = hmac_length,
            .auth_length = auth_length,
            .preamble_length = prefix_length + auth_length,
            .current_replay_id = BidirectionalState(u32).init(1),
            .timestamp = time.unixSeconds(),
        };
    }

    pub fn deinit(self: *AuthSerializer) void {
        self.fnt.cbc_free.?(self.cbc);
        self.* = undefined;
    }

    pub fn reset(_: *AuthSerializer) void {}

    pub fn serialize(
        self: *AuthSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
    ) anyerror![]u8 {
        return self.serializeAt(allocator, packet, self.timestamp);
    }

    pub fn serializeAt(
        self: *AuthSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
        timestamp: u32,
    ) anyerror![]u8 {
        const data = try packet.serializedWithCryptoAlloc(
            allocator,
            self.cbc,
            self.current_replay_id.outbound,
            timestamp,
            c.openvpn_ctrl_serialize_auth,
        );
        self.current_replay_id.outbound +%= 1;
        return data;
    }

    pub fn deserialize(
        self: *AuthSerializer,
        allocator: std.mem.Allocator,
        packet: []const u8,
        _: usize,
        _: ?usize,
    ) anyerror!ControlPacket {
        if (packet.len < self.preamble_length) return error.ControlChannelFailure;
        const swapped = try allocator.alloc(u8, packet.len);
        defer allocator.free(swapped);
        c.openvpn_data_swap_copy(
            swapped.ptr,
            packet.ptr,
            packet.len,
            self.prefix_length,
            self.auth_length,
        );
        var native_error: c_crypto.pp_crypto_error_code = c_crypto.PPCryptoErrorNone;
        if (!c_crypto.pp_crypto_verify(self.cbc, swapped.ptr, swapped.len, &native_error)) {
            return errors.cryptoError(native_error);
        }
        return self.plain.deserialize(allocator, swapped, self.auth_length, null);
    }
};

pub const CryptSerializer = struct {
    fnt: c_crypto.pp_crypto_enc_fnt,
    ctr: c_crypto.pp_crypto_ctx,
    header_length: usize,
    ad_length: usize,
    tag_length: usize,
    current_replay_id: BidirectionalState(u32),
    timestamp: u32,
    plain: PlainSerializer = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_enc_fnt,
        key: api.OpenVPNStaticKey,
    ) anyerror!CryptSerializer {
        var keys = try static_key.cryptKeys(allocator, key);
        defer keys.deinit(allocator);
        var bridge = try CryptoKeysBridge.init(allocator, &keys);
        defer bridge.deinit();
        var cipher_name: core.util.TemporaryCString = .{};
        try cipher_name.init(allocator, "AES-256-CTR");
        defer cipher_name.deinit();
        var digest_name: core.util.TemporaryCString = .{};
        try digest_name.init(allocator, "SHA256");
        defer digest_name.deinit();
        const ctr = fnt.ctr_create.?(
            cipher_name.ptr(),
            digest_name.ptr(),
            ControlConstants.ctr_tag_length,
            ControlConstants.ctr_payload_length,
            bridge.native(),
        ) orelse return error.UnsupportedAlgorithm;
        const header_length = c.OpenVPNPacketOpcodeLength + c.OpenVPNPacketSessionIdLength;
        return .{
            .fnt = fnt,
            .ctr = ctr,
            .header_length = header_length,
            .ad_length = header_length + c.OpenVPNPacketReplayIdLength + c.OpenVPNPacketReplayTimestampLength,
            .tag_length = c_crypto.pp_crypto_meta_of(ctr).tag_len,
            .current_replay_id = BidirectionalState(u32).init(1),
            .timestamp = time.unixSeconds(),
        };
    }

    pub fn deinit(self: *CryptSerializer) void {
        self.fnt.ctr_free.?(self.ctr);
        self.* = undefined;
    }

    pub fn reset(_: *CryptSerializer) void {}

    pub fn serialize(
        self: *CryptSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
    ) anyerror![]u8 {
        return self.serializeAt(allocator, packet, self.timestamp);
    }

    pub fn serializeAt(
        self: *CryptSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
        timestamp: u32,
    ) anyerror![]u8 {
        const data = try packet.serializedWithCryptoAlloc(
            allocator,
            self.ctr,
            self.current_replay_id.outbound,
            timestamp,
            c.openvpn_ctrl_serialize_crypt,
        );
        self.current_replay_id.outbound +%= 1;
        return data;
    }

    pub fn deserialize(
        self: *CryptSerializer,
        allocator: std.mem.Allocator,
        packet: []const u8,
        _: usize,
        _: ?usize,
    ) anyerror!ControlPacket {
        // Swift intentionally ignores start/end for tls-crypt framing and
        // authenticates/decrypts the complete datagram.
        if (packet.len < self.ad_length + self.tag_length) return error.ControlChannelFailure;
        const source = packet;
        const encrypted_count = source.len - self.ad_length;
        // Keep header storage separate from the crypto output capacity. The
        // Swift allocation relies on cipher/tag headroom being at least the
        // header length; making that requirement explicit is safe for exact-
        // capacity backends too.
        const crypto_capacity = c_crypto.pp_crypto_encryption_capacity(self.ctr, encrypted_count);
        const decrypted_capacity = std.math.add(usize, self.header_length, crypto_capacity) catch
            return error.OutOfMemory;
        var decrypted = try allocator.alloc(u8, decrypted_capacity);
        errdefer allocator.free(decrypted);
        var flags = c_crypto.pp_crypto_flags{
            .iv = null,
            .iv_len = 0,
            .ad = source.ptr,
            .ad_len = self.ad_length,
            .for_testing = 0,
        };
        var native_error: c_crypto.pp_crypto_error_code = c_crypto.PPCryptoErrorNone;
        const decrypted_count = c_crypto.pp_crypto_decrypt(
            self.ctr,
            decrypted.ptr + self.header_length,
            decrypted.len - self.header_length,
            source.ptr + flags.ad_len,
            encrypted_count,
            &flags,
            &native_error,
        );
        if (decrypted_count == 0) return errors.cryptoError(native_error);
        @memcpy(decrypted[0..self.header_length], source[0..self.header_length]);
        const total = self.header_length + decrypted_count;
        std.debug.assert(total <= decrypted.len);
        if (total < decrypted.len) decrypted = try allocator.realloc(decrypted, total);
        defer allocator.free(decrypted);
        return self.plain.deserialize(allocator, decrypted, 0, null);
    }
};

pub const CryptV2Serializer = struct {
    wrapped_key: []u8,
    serializer: CryptSerializer,

    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_enc_fnt,
        key: api.OpenVPNStaticKey,
        wrapped_key: api.SecureData,
    ) anyerror!CryptV2Serializer {
        const decoded = try wrapped_key.bytesAlloc(allocator);
        errdefer {
            @memset(decoded, 0);
            allocator.free(decoded);
        }
        return .{
            .wrapped_key = decoded,
            .serializer = try CryptSerializer.init(allocator, fnt, key),
        };
    }

    pub fn deinit(self: *CryptV2Serializer, allocator: std.mem.Allocator) void {
        self.serializer.deinit();
        @memset(self.wrapped_key, 0);
        allocator.free(self.wrapped_key);
        self.* = undefined;
    }

    pub fn reset(self: *CryptV2Serializer) void {
        self.serializer.reset();
    }

    pub fn serialize(
        self: *CryptV2Serializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
    ) anyerror![]u8 {
        var data = try self.serializer.serialize(allocator, packet);
        errdefer allocator.free(data);
        switch (packet.code) {
            .hardResetClientV3, .controlWkcV1 => {
                const old_len = data.len;
                data = try allocator.realloc(data, old_len + self.wrapped_key.len);
                @memcpy(data[old_len..], self.wrapped_key);
            },
            else => {},
        }
        return data;
    }

    pub fn deserialize(
        self: *CryptV2Serializer,
        allocator: std.mem.Allocator,
        data: []const u8,
        start: usize,
        end: ?usize,
    ) anyerror!ControlPacket {
        return self.serializer.deserialize(allocator, data, start, end);
    }
};

fn fillOnes(context: ?*anyopaque, destination: []u8) bool {
    const value: *u8 = @ptrCast(@alignCast(context.?));
    @memset(destination, value.*);
    return true;
}

test "plain serializer round trips control and ACK packets" {
    var interface = Serializer{ .plain = .{} };
    defer interface.deinit(std.testing.allocator);
    const sid = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const payload = [_]u8{ 9, 10, 11 };
    var original = try ControlPacket.init(.controlV1, 3, &sid, 42, &payload, null, null);
    defer original.deinit();
    const raw = try interface.serialize(std.testing.allocator, &original);
    defer std.testing.allocator.free(raw);
    var decoded = try interface.deserialize(std.testing.allocator, raw, 0, null);
    defer decoded.deinit();
    try std.testing.expectEqual(PacketCode.controlV1, decoded.code);
    try std.testing.expectEqual(@as(u32, 42), decoded.packetId());
    try std.testing.expectEqualSlices(u8, &payload, decoded.payload().?);
}

test "plain serializer rejects truncated frames" {
    var serializer: PlainSerializer = .{};
    try std.testing.expectError(error.MissingSessionId, serializer.deserialize(std.testing.allocator, &.{0x20}, 0, null));
}

test "tls-auth round trips the whole datagram and ignores bounds" {
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var secure_key = try api.SecureData.initBytesAlloc(std.testing.allocator, &key_bytes);
    defer secure_key.deinit(std.testing.allocator);
    const key = api.OpenVPNStaticKey{ .data = secure_key, .dir = null };
    const functions = c_crypto.pp_crypto_fnt_mock();
    var serializer = try AuthSerializer.init(std.testing.allocator, functions.enc, .sha256, key);
    defer serializer.deinit();

    const session_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var packet = try ControlPacket.init(.controlV1, 3, &session_id, 42, "payload", null, null);
    defer packet.deinit();
    const raw = try serializer.serializeAt(std.testing.allocator, &packet, 1234);
    defer std.testing.allocator.free(raw);
    var decoded = try serializer.deserialize(std.testing.allocator, raw, raw.len, 0);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 42), decoded.packetId());
    try std.testing.expectEqualStrings("payload", decoded.payload().?);
}

test "tls-crypt round trips the whole datagram and ignores bounds" {
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var secure_key = try api.SecureData.initBytesAlloc(std.testing.allocator, &key_bytes);
    defer secure_key.deinit(std.testing.allocator);
    const key = api.OpenVPNStaticKey{ .data = secure_key, .dir = .client };
    const functions = c_crypto.pp_crypto_fnt_mock();
    var serializer = try CryptSerializer.init(std.testing.allocator, functions.enc, key);
    defer serializer.deinit();

    const session_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const payload = [_]u8{0xa5} ** 40;
    var packet = try ControlPacket.init(.controlV1, 3, &session_id, 42, &payload, null, null);
    defer packet.deinit();
    const raw = try serializer.serializeAt(std.testing.allocator, &packet, 1234);
    defer std.testing.allocator.free(raw);

    // The Swift serializer deliberately ignores both values and authenticates
    // the complete datagram.
    var decoded = try serializer.deserialize(std.testing.allocator, raw, raw.len, 0);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 42), decoded.packetId());
    try std.testing.expectEqualSlices(u8, &payload, decoded.payload().?);
}

test "tls-crypt-v2 appends the wrapped key only to WKC opcodes" {
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var secure_key = try api.SecureData.initBytesAlloc(std.testing.allocator, &key_bytes);
    defer secure_key.deinit(std.testing.allocator);
    const wrapped_bytes = [_]u8{ 0xfa, 0xce, 0xb0, 0x0c };
    var secure_wrapped = try api.SecureData.initBytesAlloc(std.testing.allocator, &wrapped_bytes);
    defer secure_wrapped.deinit(std.testing.allocator);
    const key = api.OpenVPNStaticKey{ .data = secure_key, .dir = .client };
    const functions = c_crypto.pp_crypto_fnt_mock();
    var serializer = try CryptV2Serializer.init(
        std.testing.allocator,
        functions.enc,
        key,
        secure_wrapped,
    );
    defer serializer.deinit(std.testing.allocator);

    const session_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var wkc = try ControlPacket.init(.hardResetClientV3, 0, &session_id, 0, null, null, null);
    defer wkc.deinit();
    const wrapped = try serializer.serialize(std.testing.allocator, &wkc);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expect(std.mem.endsWith(u8, wrapped, &wrapped_bytes));

    var ordinary = try ControlPacket.init(.controlV1, 0, &session_id, 1, null, null, null);
    defer ordinary.deinit();
    const unwrapped = try serializer.serialize(std.testing.allocator, &ordinary);
    defer std.testing.allocator.free(unwrapped);
    try std.testing.expect(!std.mem.endsWith(u8, unwrapped, &wrapped_bytes));
}

const TestControlChannel = control.ControlChannel(Serializer);

test "plain control channel fragments payload and retains opcode" {
    var one: u8 = 1;
    const mock_prng = PRNG{ .context = &one, .fill_fn = fillOnes };
    const channel = try TestControlChannel.create(
        std.testing.allocator,
        mock_prng,
        .{ .plain = .{} },
    );
    defer channel.destroy();
    try channel.reset(true);
    try channel.enqueueOutboundPacketsWithCode(.controlV1, 0, &.{ 1, 2, 3, 4, 5, 6 }, 4);
    const packets = try channel.writeOutboundPackets(0);
    defer TestControlChannel.freePackets(std.testing.allocator, packets);
    try std.testing.expectEqual(@as(usize, 2), packets.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PacketCode.controlV1)), packets[0][0] >> 3);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PacketCode.controlV1)), packets[1][0] >> 3);
}

test "control channel reorders and deduplicates inbound packets" {
    var one: u8 = 1;
    const mock_prng = PRNG{ .context = &one, .fill_fn = fillOnes };
    const channel = try TestControlChannel.create(
        std.testing.allocator,
        mock_prng,
        .{ .plain = .{} },
    );
    defer channel.destroy();
    try channel.reset(true);
    const sid = channel.sessionId().?;
    const sequence = [_]u32{ 2, 0, 1, 1 };
    var handled: std.ArrayList(u32) = .empty;
    defer handled.deinit(std.testing.allocator);
    for (sequence) |packet_id| {
        const packet = try ControlPacket.init(.controlV1, 0, sid, packet_id, null, null, null);
        const ready = try channel.enqueueInboundPacket(packet);
        defer std.testing.allocator.free(ready);
        for (ready) |*item| {
            try handled.append(std.testing.allocator, item.packetId());
            item.deinit();
        }
    }
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, handled.items);
}

test "control channel suppresses retransmission until ACK" {
    var one: u8 = 1;
    const mock_prng = PRNG{ .context = &one, .fill_fn = fillOnes };
    const channel = try TestControlChannel.create(
        std.testing.allocator,
        mock_prng,
        .{ .plain = .{} },
    );
    defer channel.destroy();
    try channel.reset(true);
    try channel.enqueueOutboundPacketsWithCode(.controlV1, 0, "hello", 64);

    const first_write = try channel.writeOutboundPackets(60_000);
    defer TestControlChannel.freePackets(std.testing.allocator, first_write);
    try std.testing.expectEqual(@as(usize, 1), first_write.len);
    try std.testing.expect(channel.hasPendingAcks());

    const suppressed = try channel.writeOutboundPackets(60_000);
    defer TestControlChannel.freePackets(std.testing.allocator, suppressed);
    try std.testing.expectEqual(@as(usize, 0), suppressed.len);

    const packet_ids = [_]u32{0};
    const raw_ack = try channel.writeAcks(0, &packet_ids, channel.sessionId().?);
    defer std.testing.allocator.free(raw_ack);
    var ack = try channel.readInboundPacket(raw_ack, 0);
    defer ack.deinit();
    try std.testing.expect(!channel.hasPendingAcks());
    try std.testing.expectEqual(@as(usize, 0), channel.outbound_queue.items.len);
    // Swift retains send dates until reset, even after the corresponding ACK.
    try std.testing.expectEqual(@as(usize, 1), channel.sent_dates_ms.count());
}
