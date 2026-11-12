// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const ffi = @import("../../c/exports.zig");
const core_mod = @import("../../core/exports.zig");
const configuration_mod = @import("configuration.zig");
const constants_mod = @import("constants.zig");
const crypto_mod = @import("crypto.zig");
const helpers_mod = @import("helpers.zig");
const keys_mod = @import("keys.zig");
const packet_mod = @import("packet.zig");

const api = core_mod.api;
const openvpn_c = helpers_mod.openvpn_c;
const portable_c = ffi.portable;
const crypto_c = ffi.crypto;
const log = core_mod.logging;

const BidirectionalState = helpers_mod.BidirectionalState;
const ControlConstants = constants_mod.Control;
const ControlPacket = packet_mod.ControlPacket;
const CryptoBackend = api.CryptoBackend;
const CryptoKeys = crypto_mod.CryptoKeys;
const CryptoKeyPair = CryptoKeys.KeyPair;
const CryptoKeysBridge = crypto_mod.CryptoKeysBridge;
const PacketCode = packet_mod.PacketCode;
const StaticKey = keys_mod.StaticKey;
const ZeroingData = crypto_mod.ZeroingData;

/// Concrete serializer variants selected once when a control channel is built.
pub const Serializer = union(enum) {
    plain: PlainSerializer,
    auth: AuthSerializer,
    crypt: CryptSerializer,
    crypt_v2: CryptV2Serializer,

    pub fn forConfiguration(
        allocator: std.mem.Allocator,
        backend: CryptoBackend,
        configuration: *const api.OpenVPNConfiguration,
    ) !Serializer {
        try configuration_mod.validate(configuration);
        if (configuration.tls_wrap) |wrap| {
            return switch (wrap.strategy) {
                .auth => .{ .auth = try AuthSerializer.init(
                    allocator,
                    backend,
                    configuration_mod.fallbackDigest(configuration),
                    wrap.key,
                ) },
                .crypt => .{ .crypt = try CryptSerializer.init(
                    allocator,
                    backend,
                    wrap.key,
                ) },
                .cryptV2 => .{ .crypt_v2 = try CryptV2Serializer.init(
                    allocator,
                    backend,
                    wrap.key,
                    wrap.wrapped_key.?,
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

        if (end - offset < openvpn_c.OpenVPNPacketOpcodeLength) return error.MissingOpcode;
        const code = PacketCode.fromRaw(data[offset] >> 3) orelse return error.UnknownCode;
        const key = data[offset] & 0b111;
        offset += openvpn_c.OpenVPNPacketOpcodeLength;
        log.writef(.info, "Control: Try read packet with code {s} and key {d}", .{
            @tagName(code),
            key,
        });

        if (end - offset < openvpn_c.OpenVPNPacketSessionIdLength) return error.MissingSessionId;
        const session_id = data[offset .. offset + openvpn_c.OpenVPNPacketSessionIdLength];
        offset += openvpn_c.OpenVPNPacketSessionIdLength;

        if (end - offset < openvpn_c.OpenVPNPacketAckLengthLength) return error.MissingAckSize;
        const ack_count: usize = data[offset];
        offset += openvpn_c.OpenVPNPacketAckLengthLength;

        var ack_storage: [std.math.maxInt(u8)]u32 = undefined;
        var ack_ids: ?[]const u32 = null;
        var remote_session_id: ?[]const u8 = null;
        if (ack_count > 0) {
            const ack_bytes = ack_count * openvpn_c.OpenVPNPacketIdLength;
            if (end - offset < ack_bytes) return error.MissingAcks;
            for (ack_storage[0..ack_count]) |*ack_id| {
                ack_id.* = std.mem.readInt(u32, data[offset..][0..4], .big);
                offset += openvpn_c.OpenVPNPacketIdLength;
            }
            ack_ids = ack_storage[0..ack_count];

            if (end - offset < openvpn_c.OpenVPNPacketSessionIdLength) return error.MissingRemoteSessionId;
            remote_session_id = data[offset .. offset + openvpn_c.OpenVPNPacketSessionIdLength];
            offset += openvpn_c.OpenVPNPacketSessionIdLength;
        }

        if (code == .ackV1) {
            const ids = ack_ids orelse return error.AckPacketWithoutIds;
            const remote = remote_session_id orelse return error.AckPacketWithoutRemoteSessionId;
            return ControlPacket.initAck(key, session_id, ids, remote);
        }

        if (end - offset < openvpn_c.OpenVPNPacketIdLength) return error.MissingPacketId;
        const packet_id = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += openvpn_c.OpenVPNPacketIdLength;
        const payload: ?[]const u8 = if (offset < end) data[offset..end] else null;
        return ControlPacket.init(code, key, session_id, packet_id, payload, ack_ids, remote_session_id);
    }
};

const AuthSerializer = struct {
    functions: crypto_c.pp_crypto_enc_fnt,
    cbc: crypto_c.pp_crypto_ctx,
    prefix_length: usize,
    hmac_length: usize,
    auth_length: usize,
    preamble_length: usize,
    current_replay_id: BidirectionalState(u32),
    timestamp: u32,
    plain: PlainSerializer = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        backend: CryptoBackend,
        digest: api.OpenVPNDigest,
        key: api.OpenVPNStaticKey,
    ) !AuthSerializer {
        const functions = (try api.cryptoFunctionTable(backend)).enc;
        var keys = try deriveKeys(allocator, key);
        defer keys.deinit();
        var bridge = CryptoKeysBridge.init(&keys);
        defer bridge.deinit();
        const cbc_create = functions.cbc_create orelse
            @panic("OpenVPN crypto backend does not define cbc_create");
        const cbc = cbc_create(null, digest.raw().ptr, bridge.native()) orelse
            return error.UnsupportedAlgorithm;
        const prefix_length = openvpn_c.OpenVPNPacketOpcodeLength + openvpn_c.OpenVPNPacketSessionIdLength;
        const hmac_length = crypto_c.pp_crypto_meta_of(cbc).digest_len;
        const auth_length = hmac_length + openvpn_c.OpenVPNPacketReplayIdLength + openvpn_c.OpenVPNPacketReplayTimestampLength;
        return .{
            .functions = functions,
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
        var static_key = try StaticKey.init(allocator, key);
        defer static_key.deinit();
        const send = ZeroingData.initCopy(static_key.hmacSendKey());
        const receive = ZeroingData.initCopy(static_key.hmacReceiveKey());
        return CryptoKeys.init(null, CryptoKeyPair.init(send, receive));
    }

    pub fn deinit(self: *AuthSerializer) void {
        const cbc_free = self.functions.cbc_free orelse
            @panic("OpenVPN crypto backend does not define cbc_free");
        cbc_free(self.cbc);
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
            openvpn_c.openvpn_ctrl_serialize_auth,
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
        openvpn_c.openvpn_data_swap_copy(
            swapped.ptr,
            packet.ptr,
            packet.len,
            self.prefix_length,
            self.auth_length,
        );
        var crypto_error_code: crypto_c.pp_crypto_error_code = crypto_c.PPCryptoErrorNone;
        if (!crypto_c.pp_crypto_verify(self.cbc, swapped.ptr, swapped.len, &crypto_error_code)) {
            return ffi.errorForCryptoErrorCode(crypto_error_code);
        }
        return self.plain.deserialize(allocator, swapped, self.auth_length, null) catch |err| {
            log.writef(.fault, "Control: Channel failure: {s}", .{@errorName(err)});
            return err;
        };
    }
};

const CryptSerializer = struct {
    functions: crypto_c.pp_crypto_enc_fnt,
    ctr: crypto_c.pp_crypto_ctx,
    header_length: usize,
    ad_length: usize,
    tag_length: usize,
    current_replay_id: BidirectionalState(u32),
    timestamp: u32,
    plain: PlainSerializer = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        backend: CryptoBackend,
        key: api.OpenVPNStaticKey,
    ) !CryptSerializer {
        const functions = (try api.cryptoFunctionTable(backend)).enc;
        var keys = try deriveKeys(allocator, key);
        defer keys.deinit();
        var bridge = CryptoKeysBridge.init(&keys);
        defer bridge.deinit();
        const cipher_name: [:0]const u8 = "AES-256-CTR";
        const digest_name: [:0]const u8 = "SHA256";
        const ctr_create = functions.ctr_create orelse
            @panic("OpenVPN crypto backend does not define ctr_create");
        const ctr = ctr_create(
            cipher_name.ptr,
            digest_name.ptr,
            ControlConstants.ctr_tag_length,
            ControlConstants.ctr_payload_length,
            bridge.native(),
        ) orelse return error.UnsupportedAlgorithm;
        const header_length = openvpn_c.OpenVPNPacketOpcodeLength + openvpn_c.OpenVPNPacketSessionIdLength;
        return .{
            .functions = functions,
            .ctr = ctr,
            .header_length = header_length,
            .ad_length = header_length + openvpn_c.OpenVPNPacketReplayIdLength + openvpn_c.OpenVPNPacketReplayTimestampLength,
            .tag_length = crypto_c.pp_crypto_meta_of(ctr).tag_len,
            .current_replay_id = BidirectionalState(u32).init(1),
            .timestamp = unixSeconds(),
        };
    }

    fn deriveKeys(
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) !CryptoKeys {
        var static_key = try StaticKey.init(allocator, key);
        defer static_key.deinit();
        const cipher_send_key = try static_key.cipherEncryptKey();
        const cipher_receive_key = try static_key.cipherDecryptKey();
        const cipher_send = ZeroingData.initCopy(cipher_send_key);
        const cipher_receive = ZeroingData.initCopy(cipher_receive_key);
        const hmac_send = ZeroingData.initCopy(static_key.hmacSendKey());
        const hmac_receive = ZeroingData.initCopy(static_key.hmacReceiveKey());
        return CryptoKeys.init(
            CryptoKeyPair.init(cipher_send, cipher_receive),
            CryptoKeyPair.init(hmac_send, hmac_receive),
        );
    }

    pub fn deinit(self: *CryptSerializer) void {
        const ctr_free = self.functions.ctr_free orelse
            @panic("OpenVPN crypto backend does not define ctr_free");
        ctr_free(self.ctr);
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
            openvpn_c.openvpn_ctrl_serialize_crypt,
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
        const crypto_capacity = crypto_c.pp_crypto_encryption_capacity(self.ctr, encrypted_count);
        const decrypted_capacity = std.math.add(usize, self.header_length, crypto_capacity) catch
            return error.OutOfMemory;
        var decrypted = try allocator.alloc(u8, decrypted_capacity);
        errdefer allocator.free(decrypted);
        var flags = crypto_c.pp_crypto_flags{
            .iv = null,
            .iv_len = 0,
            .ad = source.ptr,
            .ad_len = self.ad_length,
            .for_testing = 0,
        };
        var crypto_error_code: crypto_c.pp_crypto_error_code = crypto_c.PPCryptoErrorNone;
        const decrypted_count = crypto_c.pp_crypto_decrypt(
            self.ctr,
            decrypted.ptr + self.header_length,
            decrypted.len - self.header_length,
            source.ptr + flags.ad_len,
            encrypted_count,
            &flags,
            &crypto_error_code,
        );
        if (decrypted_count == 0) return ffi.errorForCryptoErrorCode(crypto_error_code);
        @memcpy(decrypted[0..self.header_length], source[0..self.header_length]);
        const total = self.header_length + decrypted_count;
        if (total > decrypted.len)
            @panic("OpenVPN crypto backend returned plaintext larger than its destination buffer");
        if (total < decrypted.len) decrypted = try allocator.realloc(decrypted, total);
        defer allocator.free(decrypted);
        return self.plain.deserialize(allocator, decrypted, 0, null) catch |err| {
            log.writef(.fault, "Control: Channel failure: {s}", .{@errorName(err)});
            return err;
        };
    }
};

const CryptV2Serializer = struct {
    wrapped_key: []u8,
    serializer: CryptSerializer,

    pub fn init(
        allocator: std.mem.Allocator,
        backend: CryptoBackend,
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
            .serializer = try CryptSerializer.init(allocator, backend, key),
        };
    }

    pub fn deinit(self: *CryptV2Serializer, allocator: std.mem.Allocator) void {
        self.serializer.deinit();
        @memset(self.wrapped_key, 0);
        allocator.free(self.wrapped_key);
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

fn unixSeconds() u32 {
    return portable_c.pp_time_unix_seconds();
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
