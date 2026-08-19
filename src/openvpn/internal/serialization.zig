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
const c_common = c_exports_mod.common;
const c_crypto = c_exports_mod.crypto;
const log = core_mod.logging;

const BidirectionalState = helpers_mod.BidirectionalState;
const ControlConstants = constants_mod.Control;
const ControlPacket = packet_mod.ControlPacket;
const CryptoBackend = c_exports_mod.CryptoBackend;
const CryptoKeys = crypto_mod.CryptoKeys;
const CryptoKeyPair = CryptoKeys.KeyPair;
const CryptoKeysBridge = crypto_mod.CryptoKeysBridge;
const PacketCode = packet_mod.PacketCode;
const ZeroingData = crypto_mod.ZeroingData;

pub const StaticKey = struct {
    pub const ParseError = std.mem.Allocator.Error || error{InvalidStaticKey};

    const content_length = 256;
    const key_count = 4;
    const key_length = content_length / key_count;
    const file_head = "-----BEGIN OpenVPN Static key V1-----";
    const file_foot = "-----END OpenVPN Static key V1-----";
    const crypt_v2_file_head = "-----BEGIN OpenVPN tls-crypt-v2 client key-----";
    const crypt_v2_file_foot = "-----END OpenVPN tls-crypt-v2 client key-----";

    data: ZeroingData,
    direction: ?api.OpenVPNStaticKeyDirection,

    pub fn init(
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) !StaticKey {
        const bytes = try key.data.bytesAlloc(allocator);
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        return initBytes(allocator, bytes, key.dir);
    }

    pub fn initFile(
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        direction: ?api.OpenVPNStaticKeyDirection,
    ) ParseError!StaticKey {
        var hex: std.ArrayList(u8) = .empty;
        defer {
            @memset(hex.items, 0);
            hex.deinit(allocator);
        }

        var in_key = false;
        for (lines) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (std.ascii.eqlIgnoreCase(line, file_head)) {
                in_key = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, file_foot)) break;
            if (!in_key) continue;
            if (!core_mod.util.containsOnly(line, "0123456789abcdefABCDEF"))
                return error.InvalidStaticKey;
            try hex.appendSlice(allocator, line);
        }
        if (hex.items.len != content_length * 2) return error.InvalidStaticKey;

        var bytes: [content_length]u8 = undefined;
        defer @memset(&bytes, 0);
        _ = std.fmt.hexToBytes(&bytes, hex.items) catch return error.InvalidStaticKey;
        return initBytes(allocator, &bytes, direction);
    }

    pub fn parseFileAlloc(
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        direction: ?api.OpenVPNStaticKeyDirection,
    ) ParseError!api.OpenVPNStaticKey {
        var key = try initFile(allocator, lines, direction);
        defer key.deinit(allocator);
        return key.apiKeyAlloc(allocator);
    }

    pub fn parseCryptV2FileAlloc(
        allocator: std.mem.Allocator,
        lines: []const []const u8,
    ) ParseError!api.OpenVPNTLSWrap {
        var base64: std.ArrayList(u8) = .empty;
        defer {
            @memset(base64.items, 0);
            base64.deinit(allocator);
        }
        var in_key = false;
        for (lines) |line| {
            if (line.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(line, crypt_v2_file_head)) {
                in_key = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, crypt_v2_file_foot)) break;
            if (in_key) try base64.appendSlice(allocator, line);
        }

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64.items) catch
            return error.InvalidStaticKey;
        const decoded = try allocator.alloc(u8, decoded_len);
        defer {
            @memset(decoded, 0);
            allocator.free(decoded);
        }
        std.base64.standard.Decoder.decode(decoded, base64.items) catch
            return error.InvalidStaticKey;
        if (decoded.len <= content_length) return error.InvalidStaticKey;

        var static_key = try initBytes(allocator, decoded[0..content_length], .client);
        defer static_key.deinit(allocator);
        var key = try static_key.apiKeyAlloc(allocator);
        errdefer key.deinit(allocator);
        const wrapped_key = try api.SecureData.initBytesAlloc(allocator, decoded[content_length..]);
        return .{
            .strategy = .cryptV2,
            .key = key,
            .wrapped_key = wrapped_key,
        };
    }

    pub fn deinit(self: *StaticKey, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    pub fn cipherEncryptKey(self: StaticKey) ![]const u8 {
        const direction = self.direction orelse return error.MissingStaticKeyDirection;
        return self.keyAt(switch (direction) {
            .server => 0,
            .client => 2,
        });
    }

    pub fn cipherDecryptKey(self: StaticKey) ![]const u8 {
        const direction = self.direction orelse return error.MissingStaticKeyDirection;
        return self.keyAt(switch (direction) {
            .server => 2,
            .client => 0,
        });
    }

    pub fn hmacSendKey(self: StaticKey) []const u8 {
        return self.keyAt(if (self.direction == .client) 3 else 1);
    }

    pub fn hmacReceiveKey(self: StaticKey) []const u8 {
        return self.keyAt(if (self.direction == .server) 3 else 1);
    }

    pub fn hexStringAlloc(self: StaticKey, allocator: std.mem.Allocator) ![]u8 {
        const bytes = self.data.asSlice();
        const hex = try allocator.alloc(u8, bytes.len * 2);
        const alphabet = "0123456789abcdef";
        for (bytes, 0..) |byte, index| {
            hex[index * 2] = alphabet[byte >> 4];
            hex[index * 2 + 1] = alphabet[byte & 0x0f];
        }
        return hex;
    }

    pub fn fileContentsAlloc(self: StaticKey, allocator: std.mem.Allocator) ![]u8 {
        const hex = try self.hexStringAlloc(allocator);
        defer {
            @memset(hex, 0);
            allocator.free(hex);
        }

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        writer.print("# 2048 bit OpenVPN static key\n{s}\n", .{file_head}) catch
            return error.OutOfMemory;
        var offset: usize = 0;
        while (offset < hex.len) : (offset += 32) {
            writer.print("{s}\n", .{hex[offset..@min(offset + 32, hex.len)]}) catch
                return error.OutOfMemory;
        }
        writer.writeAll(file_foot) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    pub fn cryptV2FileContentsAlloc(
        self: StaticKey,
        allocator: std.mem.Allocator,
        wrapped_key: api.SecureData,
    ) ![]u8 {
        const wrapped = try wrapped_key.bytesAlloc(allocator);
        defer {
            @memset(wrapped, 0);
            allocator.free(wrapped);
        }
        const key_bytes = self.data.asSlice();
        const combined_len = std.math.add(usize, key_bytes.len, wrapped.len) catch
            return error.OutOfMemory;
        const combined = try allocator.alloc(u8, combined_len);
        defer {
            @memset(combined, 0);
            allocator.free(combined);
        }
        @memcpy(combined[0..key_bytes.len], key_bytes);
        @memcpy(combined[key_bytes.len..], wrapped);

        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(combined.len));
        defer {
            @memset(encoded, 0);
            allocator.free(encoded);
        }
        _ = std.base64.standard.Encoder.encode(encoded, combined);

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        writer.print("{s}\n", .{crypt_v2_file_head}) catch return error.OutOfMemory;
        var offset: usize = 0;
        while (offset < encoded.len) : (offset += 64) {
            writer.print("{s}\n", .{encoded[offset..@min(offset + 64, encoded.len)]}) catch
                return error.OutOfMemory;
        }
        writer.writeAll(crypt_v2_file_foot) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    fn initBytes(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        direction: ?api.OpenVPNStaticKeyDirection,
    ) ParseError!StaticKey {
        if (bytes.len != content_length) return error.InvalidStaticKey;
        return .{
            .data = try ZeroingData.initCopy(allocator, bytes),
            .direction = direction,
        };
    }

    fn apiKeyAlloc(self: StaticKey, allocator: std.mem.Allocator) !api.OpenVPNStaticKey {
        return .{
            .data = try api.SecureData.initBytesAlloc(allocator, self.data.asSlice()),
            .dir = self.direction,
        };
    }

    fn keyAt(self: StaticKey, index: usize) []const u8 {
        const bytes = self.data.asSlice();
        if (bytes.len != content_length)
            @panic("invalid OpenVPN static key length");
        return bytes[index * key_length .. (index + 1) * key_length];
    }
};

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

        if (end - offset < c.OpenVPNPacketOpcodeLength) return error.MissingOpcode;
        const code = PacketCode.fromRaw(data[offset] >> 3) orelse return error.UnknownCode;
        const key = data[offset] & 0b111;
        offset += c.OpenVPNPacketOpcodeLength;
        log.writef(.info, "Control: Try read packet with code {s} and key {d}", .{
            @tagName(code),
            key,
        });

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
    functions: c_crypto.pp_crypto_enc_fnt,
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
        backend: CryptoBackend,
        digest: api.OpenVPNDigest,
        key: api.OpenVPNStaticKey,
    ) !AuthSerializer {
        const functions = (try c_exports_mod.cryptoFunctionTable(backend)).enc;
        var keys = try deriveKeys(allocator, key);
        defer keys.deinit(allocator);
        var bridge = try CryptoKeysBridge.init(allocator, &keys);
        defer bridge.deinit();
        const cbc = functions.cbc_create.?(null, digest.raw().ptr, bridge.native()) orelse return error.UnsupportedAlgorithm;
        const prefix_length = c.OpenVPNPacketOpcodeLength + c.OpenVPNPacketSessionIdLength;
        const hmac_length = c_crypto.pp_crypto_meta_of(cbc).digest_len;
        const auth_length = hmac_length + c.OpenVPNPacketReplayIdLength + c.OpenVPNPacketReplayTimestampLength;
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
        defer static_key.deinit(allocator);
        var send = try ZeroingData.initCopy(allocator, static_key.hmacSendKey());
        errdefer send.deinit(allocator);
        const receive = try ZeroingData.initCopy(allocator, static_key.hmacReceiveKey());
        return CryptoKeys.init(null, CryptoKeyPair.init(send, receive));
    }

    pub fn deinit(self: *AuthSerializer) void {
        self.functions.cbc_free.?(self.cbc);
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
        return self.plain.deserialize(allocator, swapped, self.auth_length, null) catch |err| {
            log.writef(.fault, "Control: Channel failure: {s}", .{@errorName(err)});
            return err;
        };
    }
};

const CryptSerializer = struct {
    functions: c_crypto.pp_crypto_enc_fnt,
    ctr: c_crypto.pp_crypto_ctx,
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
        const functions = (try c_exports_mod.cryptoFunctionTable(backend)).enc;
        var keys = try deriveKeys(allocator, key);
        defer keys.deinit(allocator);
        var bridge = try CryptoKeysBridge.init(allocator, &keys);
        defer bridge.deinit();
        const cipher_name: [:0]const u8 = "AES-256-CTR";
        const digest_name: [:0]const u8 = "SHA256";
        const ctr = functions.ctr_create.?(
            cipher_name.ptr,
            digest_name.ptr,
            ControlConstants.ctr_tag_length,
            ControlConstants.ctr_payload_length,
            bridge.native(),
        ) orelse return error.UnsupportedAlgorithm;
        const header_length = c.OpenVPNPacketOpcodeLength + c.OpenVPNPacketSessionIdLength;
        return .{
            .functions = functions,
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
        var static_key = try StaticKey.init(allocator, key);
        defer static_key.deinit(allocator);
        var cipher_send = try ZeroingData.initCopy(allocator, try static_key.cipherEncryptKey());
        errdefer cipher_send.deinit(allocator);
        var cipher_receive = try ZeroingData.initCopy(allocator, try static_key.cipherDecryptKey());
        errdefer cipher_receive.deinit(allocator);
        var hmac_send = try ZeroingData.initCopy(allocator, static_key.hmacSendKey());
        errdefer hmac_send.deinit(allocator);
        const hmac_receive = try ZeroingData.initCopy(allocator, static_key.hmacReceiveKey());
        return CryptoKeys.init(
            CryptoKeyPair.init(cipher_send, cipher_receive),
            CryptoKeyPair.init(hmac_send, hmac_receive),
        );
    }

    pub fn deinit(self: *CryptSerializer) void {
        self.functions.ctr_free.?(self.ctr);
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
    return c_common.pp_time_unix_seconds();
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
