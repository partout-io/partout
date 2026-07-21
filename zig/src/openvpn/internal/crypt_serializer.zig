// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const api = core.api;
const c_crypto = @import("../../c/exports.zig").crypto;
const c = @import("c.zig").api;
const BidirectionalState = @import("bidirectional_state.zig").BidirectionalState;
const CControlPacket = @import("c_control_packet.zig").CControlPacket;
const Constants = @import("constants.zig").Constants;
const ControlChannelSerializer = @import("control_channel_serializer.zig").ControlChannelSerializer;
const CryptoKeysBridge = @import("crypto_keys_bridge.zig").CryptoKeysBridge;
const errors = @import("errors.zig");
const PlainSerializer = @import("plain_serializer.zig").PlainSerializer;
const static_key = @import("static_key_helpers.zig");
const time = @import("time_helpers.zig");

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
            Constants.ControlChannel.ctr_tag_length,
            Constants.ControlChannel.ctr_payload_length,
            bridge.native(),
        ) orelse return error.CryptoCreation;
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

    pub fn create(
        allocator: std.mem.Allocator,
        fnt: c_crypto.pp_crypto_enc_fnt,
        key: api.OpenVPNStaticKey,
    ) anyerror!ControlChannelSerializer {
        const self = try allocator.create(CryptSerializer);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, fnt, key);
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *CryptSerializer) void {
        self.fnt.ctr_free.?(self.ctr);
        self.* = undefined;
    }

    pub fn reset(_: *CryptSerializer) void {}

    pub fn serialize(
        self: *CryptSerializer,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
    ) anyerror![]u8 {
        return self.serializeAt(allocator, packet, self.timestamp);
    }

    pub fn serializeAt(
        self: *CryptSerializer,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
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
    ) anyerror!CControlPacket {
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
        if (decrypted_count == 0) return errors.CCryptoError.init(native_error).toError();
        @memcpy(decrypted[0..self.header_length], source[0..self.header_length]);
        const total = self.header_length + decrypted_count;
        std.debug.assert(total <= decrypted.len);
        if (total < decrypted.len) decrypted = try allocator.realloc(decrypted, total);
        defer allocator.free(decrypted);
        return self.plain.deserialize(allocator, decrypted, 0, null);
    }

    fn erasedReset(raw: *anyopaque) void {
        reset(@ptrCast(@alignCast(raw)));
    }
    fn erasedSerialize(raw: *anyopaque, allocator: std.mem.Allocator, packet: *const CControlPacket) anyerror![]u8 {
        return serialize(@ptrCast(@alignCast(raw)), allocator, packet);
    }
    fn erasedDeserialize(raw: *anyopaque, allocator: std.mem.Allocator, data: []const u8, start: usize, end: ?usize) anyerror!CControlPacket {
        return deserialize(@ptrCast(@alignCast(raw)), allocator, data, start, end);
    }
    fn erasedDestroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *CryptSerializer = @ptrCast(@alignCast(raw));
        self.deinit();
        allocator.destroy(self);
    }
    const vtable: ControlChannelSerializer.VTable = .{
        .reset = erasedReset,
        .serialize = erasedSerialize,
        .deserialize = erasedDeserialize,
        .destroy = erasedDestroy,
    };
};

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
    var packet = try CControlPacket.init(.controlV1, 3, &session_id, 42, &payload, null, null);
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
