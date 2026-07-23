// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c_exports_mod = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const crypto_mod = @import("crypto.zig");
const errors_mod = @import("errors.zig");
const helpers_mod = @import("helpers.zig");
const packet_mod = @import("packet.zig");

const api = core_mod.api;
const c = helpers_mod.c;
const c_crypto = c_exports_mod.crypto;

const BidirectionalState = helpers_mod.BidirectionalState;
const ControlConstants = constants_mod.Control;
const ControlPacket = packet_mod.ControlPacket;
const CryptoKeys = crypto_mod.CryptoKeys;
const CryptoKeyPair = CryptoKeys.KeyPair;
const CryptoKeysBridge = crypto_mod.CryptoKeysBridge;
const PacketCode = packet_mod.PacketCode;
const ZeroingData = crypto_mod.ZeroingData;

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
    ) !Serializer {
        if (configuration.tls_wrap) |wrap| {
            return switch (wrap.strategy) {
                .auth => .{ .auth = try AuthSerializer.init(
                    allocator,
                    fnt,
                    configuration_mod.fallbackDigest(configuration),
                    wrap.key,
                ) },
                .crypt => .{ .crypt = try CryptSerializer.init(
                    allocator,
                    fnt,
                    wrap.key,
                ) },
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
    ) ![]u8 {
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
    ) !ControlPacket {
        return switch (self.*) {
            inline else => |*value| value.deserialize(allocator, data, start, end),
        };
    }
};

const PlainSerializer = struct {
    pub fn reset(_: *PlainSerializer) void {}

    pub fn serialize(
        _: *PlainSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
    ) ![]u8 {
        return packet.serializedAlloc(allocator);
    }

    pub fn deserialize(
        _: *PlainSerializer,
        _: std.mem.Allocator,
        data: []const u8,
        start: usize,
        optional_end: ?usize,
    ) !ControlPacket {
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

const AuthSerializer = struct {
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
    ) !AuthSerializer {
        var keys = try deriveKeys(allocator, key);
        defer keys.deinit(allocator);
        var bridge = try CryptoKeysBridge.init(allocator, &keys);
        defer bridge.deinit();
        var digest_name: core_mod.util.TemporaryCString = .{};
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
            .timestamp = unixSeconds(),
        };
    }

    fn deriveKeys(
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) !CryptoKeys {
        const bytes = try decodeStaticKey(allocator, key);
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        const send_index: usize = switch (key.dir orelse .server) {
            .server => 1,
            .client => 3,
        };
        const receive_index: usize = switch (key.dir orelse .client) {
            .server => 3,
            .client => 1,
        };
        var send = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, send_index));
        errdefer send.deinit(allocator);
        const receive = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, receive_index));
        return CryptoKeys.init(null, CryptoKeyPair.init(send, receive));
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
    ) ![]u8 {
        return self.serializeAt(allocator, packet, self.timestamp);
    }

    pub fn serializeAt(
        self: *AuthSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
        timestamp: u32,
    ) ![]u8 {
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
    ) !ControlPacket {
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
            return errors_mod.cryptoError(native_error);
        }
        return self.plain.deserialize(allocator, swapped, self.auth_length, null);
    }
};

const CryptSerializer = struct {
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
    ) !CryptSerializer {
        var keys = try deriveKeys(allocator, key);
        defer keys.deinit(allocator);
        var bridge = try CryptoKeysBridge.init(allocator, &keys);
        defer bridge.deinit();
        var cipher_name: core_mod.util.TemporaryCString = .{};
        try cipher_name.init(allocator, "AES-256-CTR");
        defer cipher_name.deinit();
        var digest_name: core_mod.util.TemporaryCString = .{};
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
            .timestamp = unixSeconds(),
        };
    }

    fn deriveKeys(
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) !CryptoKeys {
        const direction = key.dir orelse return error.MissingStaticKeyDirection;
        const bytes = try decodeStaticKey(allocator, key);
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        const cipher_send_index: usize = if (direction == .server) 0 else 2;
        const cipher_receive_index: usize = if (direction == .server) 2 else 0;
        const hmac_send_index: usize = if (direction == .server) 1 else 3;
        const hmac_receive_index: usize = if (direction == .server) 3 else 1;

        var cipher_send = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, cipher_send_index));
        errdefer cipher_send.deinit(allocator);
        var cipher_receive = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, cipher_receive_index));
        errdefer cipher_receive.deinit(allocator);
        var hmac_send = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, hmac_send_index));
        errdefer hmac_send.deinit(allocator);
        const hmac_receive = try ZeroingData.initCopy(allocator, staticKeyQuadrant(bytes, hmac_receive_index));
        return CryptoKeys.init(
            CryptoKeyPair.init(cipher_send, cipher_receive),
            CryptoKeyPair.init(hmac_send, hmac_receive),
        );
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
    ) ![]u8 {
        return self.serializeAt(allocator, packet, self.timestamp);
    }

    pub fn serializeAt(
        self: *CryptSerializer,
        allocator: std.mem.Allocator,
        packet: *const ControlPacket,
        timestamp: u32,
    ) ![]u8 {
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
    ) !ControlPacket {
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
        if (decrypted_count == 0) return errors_mod.cryptoError(native_error);
        @memcpy(decrypted[0..self.header_length], source[0..self.header_length]);
        const total = self.header_length + decrypted_count;
        std.debug.assert(total <= decrypted.len);
        if (total < decrypted.len) decrypted = try allocator.realloc(decrypted, total);
        defer allocator.free(decrypted);
        return self.plain.deserialize(allocator, decrypted, 0, null);
    }
};

const CryptV2Serializer = struct {
    wrapped_key: []u8,
    serializer: CryptSerializer,

    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_enc_fnt,
        key: api.OpenVPNStaticKey,
        wrapped_key: api.SecureData,
    ) !CryptV2Serializer {
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
    ) ![]u8 {
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
    ) !ControlPacket {
        return self.serializer.deserialize(allocator, data, start, end);
    }
};

fn decodeStaticKey(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) ![]u8 {
    const bytes = try key.data.bytesAlloc(allocator);
    errdefer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    if (bytes.len != static_key_content_length) return error.InvalidStaticKey;
    return bytes;
}

fn staticKeyQuadrant(bytes: []const u8, index: usize) []const u8 {
    return bytes[index * static_key_length .. (index + 1) * static_key_length];
}

fn unixSeconds() u32 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    if (seconds <= 0) return 0;
    return @truncate(@as(u64, @intCast(seconds)));
}

pub const testing = struct {
    pub const Auth = AuthSerializer;
    pub const Crypt = CryptSerializer;
    pub const CryptV2 = CryptV2Serializer;
    pub const Plain = PlainSerializer;
    pub fn buildAuthKeys(
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) !CryptoKeys {
        return AuthSerializer.deriveKeys(allocator, key);
    }

    pub fn buildCryptKeys(
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) !CryptoKeys {
        return CryptSerializer.deriveKeys(allocator, key);
    }
};

const static_key_content_length = 256;
const static_key_length = 64;
