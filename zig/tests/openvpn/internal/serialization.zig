// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const c_crypto = source.c_crypto;
const packet = source.openvpn_internal.packet;
const serialization = source.openvpn_internal.serialization;

const ControlPacket = packet.ControlPacket;
const PacketCode = packet.PacketCode;
const AuthSerializer = serialization.testing.Auth;
const CryptSerializer = serialization.testing.Crypt;
const CryptV2Serializer = serialization.testing.CryptV2;
const PlainSerializer = serialization.testing.Plain;
const Serializer = serialization.Serializer;

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
    var control_packet = try ControlPacket.init(.controlV1, 3, &session_id, 42, "payload", null, null);
    defer control_packet.deinit();
    const raw = try serializer.serializeAt(std.testing.allocator, &control_packet, 1234);
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
    var control_packet = try ControlPacket.init(.controlV1, 3, &session_id, 42, &payload, null, null);
    defer control_packet.deinit();
    const raw = try serializer.serializeAt(std.testing.allocator, &control_packet, 1234);
    defer std.testing.allocator.free(raw);
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
    var serializer = try CryptV2Serializer.init(std.testing.allocator, functions.enc, key, secure_wrapped);
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
