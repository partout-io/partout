// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../../core/exports.zig");
const api = core.api;
const c = @import("c.zig").api;
const BidirectionalState = @import("bidirectional_state.zig").BidirectionalState;
const CControlPacket = @import("c_control_packet.zig").CControlPacket;
const ControlChannelSerializer = @import("control_channel_serializer.zig").ControlChannelSerializer;
const CryptoKeysBridge = @import("crypto_keys_bridge.zig").CryptoKeysBridge;
const errors = @import("errors.zig");
const PlainSerializer = @import("plain_serializer.zig").PlainSerializer;
const static_key = @import("static_key_helpers.zig");
const time = @import("time_helpers.zig");

pub const AuthSerializer = struct {
    fnt: c.pp_crypto_enc_fnt,
    cbc: c.pp_crypto_ctx,
    prefix_length: usize,
    hmac_length: usize,
    auth_length: usize,
    preamble_length: usize,
    current_replay_id: BidirectionalState(u32),
    timestamp: u32,
    plain: PlainSerializer = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        fnt: c.pp_crypto_enc_fnt,
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
        const cbc = fnt.cbc_create.?(null, digest_name.ptr(), bridge.native()) orelse return error.CryptoCreation;
        const prefix_length = c.OpenVPNPacketOpcodeLength + c.OpenVPNPacketSessionIdLength;
        const hmac_length = c.pp_crypto_meta_of(cbc).digest_len;
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

    pub fn create(
        allocator: std.mem.Allocator,
        fnt: c.pp_crypto_enc_fnt,
        digest: api.OpenVPNDigest,
        key: api.OpenVPNStaticKey,
    ) anyerror!ControlChannelSerializer {
        const self = try allocator.create(AuthSerializer);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, fnt, digest, key);
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *AuthSerializer) void {
        self.fnt.cbc_free.?(self.cbc);
        self.* = undefined;
    }

    pub fn reset(_: *AuthSerializer) void {}

    pub fn serialize(
        self: *AuthSerializer,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
    ) anyerror![]u8 {
        return self.serializeAt(allocator, packet, self.timestamp);
    }

    pub fn serializeAt(
        self: *AuthSerializer,
        allocator: std.mem.Allocator,
        packet: *const CControlPacket,
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
    ) anyerror!CControlPacket {
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
        var native_error: c.pp_crypto_error_code = c.PPCryptoErrorNone;
        if (!c.pp_crypto_verify(self.cbc, swapped.ptr, swapped.len, &native_error)) {
            return errors.CCryptoError.init(native_error).toError();
        }
        return self.plain.deserialize(allocator, swapped, self.auth_length, null);
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
        const self: *AuthSerializer = @ptrCast(@alignCast(raw));
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

test "tls-auth round trips the whole datagram and ignores bounds" {
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var secure_key = try api.SecureData.initBytesAlloc(std.testing.allocator, &key_bytes);
    defer secure_key.deinit(std.testing.allocator);
    const key = api.OpenVPNStaticKey{ .data = secure_key, .dir = null };
    const functions = c.pp_crypto_fnt_mock();
    var serializer = try AuthSerializer.init(std.testing.allocator, functions.enc, .sha256, key);
    defer serializer.deinit();

    const session_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var packet = try CControlPacket.init(.controlV1, 3, &session_id, 42, "payload", null, null);
    defer packet.deinit();
    const raw = try serializer.serializeAt(std.testing.allocator, &packet, 1234);
    defer std.testing.allocator.free(raw);
    var decoded = try serializer.deserialize(std.testing.allocator, raw, raw.len, 0);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 42), decoded.packetId());
    try std.testing.expectEqualStrings("payload", decoded.payload().?);
}
