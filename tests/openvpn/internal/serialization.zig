// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const control_serializers = source.openvpn_internal.control_serializers;
const packet = source.openvpn_internal.packet;

const ControlPacket = packet.ControlPacket;
const PacketCode = packet.PacketCode;
const AuthSerializer = control_serializers.testing.Auth;
const CryptSerializer = control_serializers.testing.Crypt;
const CryptV2Serializer = control_serializers.testing.CryptV2;
const PlainSerializer = control_serializers.testing.Plain;
const Serializer = control_serializers.Serializer;
const buildAuthKeys = control_serializers.testing.buildAuthKeys;
const buildCryptKeys = control_serializers.testing.buildCryptKeys;

const static_key_content_length = 256;
const static_key_length = 64;

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

test "client and server tls-crypt keys are complementary" {
    var bytes: [static_key_content_length]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var secure = try api.SecureData.initBytesAlloc(std.testing.allocator, &bytes);
    defer secure.deinit(std.testing.allocator);
    var client = try buildCryptKeys(std.testing.allocator, .{ .data = secure, .dir = .client });
    defer client.deinit();
    var server = try buildCryptKeys(std.testing.allocator, .{ .data = secure, .dir = .server });
    defer server.deinit();
    try std.testing.expectEqualSlices(
        u8,
        client.cipher.?.encryption_key.asSlice(),
        server.cipher.?.decryption_key.asSlice(),
    );
    try std.testing.expectEqualSlices(
        u8,
        client.digest.?.encryption_key.asSlice(),
        server.digest.?.decryption_key.asSlice(),
    );
}

test "tls-auth without key direction uses the shared HMAC quadrant" {
    var bytes: [static_key_content_length]u8 = undefined;
    for (0..4) |quadrant_index| {
        @memset(
            bytes[quadrant_index * static_key_length .. (quadrant_index + 1) * static_key_length],
            @as(u8, @intCast(quadrant_index)),
        );
    }
    var secure = try api.SecureData.initBytesAlloc(std.testing.allocator, &bytes);
    defer secure.deinit(std.testing.allocator);
    var keys = try buildAuthKeys(std.testing.allocator, .{ .data = secure, .dir = null });
    defer keys.deinit();
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.encryption_key.asSlice(), 1));
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.decryption_key.asSlice(), 1));
}

test "static tls-auth key directions match the Swift key vectors" {
    const allocator = std.testing.allocator;
    var secure = (try api.SecureData.parseHexAlloc(allocator, static_key_hex)).?;
    defer secure.deinit(allocator);
    const shared = try hexBytes(
        allocator,
        "cf55d863fcbe314df5f0b45dbe974d9bde33ef5b4803c3985531c6c23ca6906d6cd028efc8585d1b9e71003566bd7891b9cc9212bcba510109922eed87f5c8e6",
    );
    defer allocator.free(shared);
    const client_send = try hexBytes(
        allocator,
        "778a6b35a124e700920879f1d003ba93dccdb953cdf32bea03f365760b0ed8002098d4ce20d045b45a83a8432cc737677aed27125592a7148d25c87fdbe0a3f6",
    );
    defer allocator.free(client_send);

    var bidirectional = try buildAuthKeys(allocator, .{
        .data = secure,
        .dir = null,
    });
    defer bidirectional.deinit();
    try std.testing.expectEqualSlices(
        u8,
        shared,
        bidirectional.digest.?.encryption_key.asSlice(),
    );
    try std.testing.expectEqualSlices(
        u8,
        shared,
        bidirectional.digest.?.decryption_key.asSlice(),
    );

    var client = try buildAuthKeys(allocator, .{
        .data = secure,
        .dir = .client,
    });
    defer client.deinit();
    try std.testing.expectEqualSlices(
        u8,
        client_send,
        client.digest.?.encryption_key.asSlice(),
    );
    try std.testing.expectEqualSlices(
        u8,
        shared,
        client.digest.?.decryption_key.asSlice(),
    );
}

test "tls-auth round trips the whole datagram and ignores bounds" {
    var key_bytes: [256]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| byte.* = @truncate(index);
    var secure_key = try api.SecureData.initBytesAlloc(std.testing.allocator, &key_bytes);
    defer secure_key.deinit(std.testing.allocator);
    const key = api.OpenVPNStaticKey{ .data = secure_key, .dir = null };
    var serializer = try AuthSerializer.init(std.testing.allocator, .mock, .sha256, key);
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
    var serializer = try CryptSerializer.init(std.testing.allocator, .mock, key);
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
    var serializer = try CryptV2Serializer.init(std.testing.allocator, .mock, key, secure_wrapped);
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

const static_key_hex =
    "48d9999bd71095b10649c7cb471c1051" ++
    "b1afdece597cea06909b99303a18c674" ++
    "01597b12c04a787e98cdb619ee960d90" ++
    "a0165529dc650f3a5c6fbe77c91c137d" ++
    "cf55d863fcbe314df5f0b45dbe974d9b" ++
    "de33ef5b4803c3985531c6c23ca6906d" ++
    "6cd028efc8585d1b9e71003566bd7891" ++
    "b9cc9212bcba510109922eed87f5c8e6" ++
    "6d8e59cbd82575261f02777372b2cd4c" ++
    "a5214c4a6513ff26dd568f574fd40d6c" ++
    "d450fc788160ff68434ce2bf6afb00e7" ++
    "10a3198538f14c4d45d84ab42637872e" ++
    "778a6b35a124e700920879f1d003ba93" ++
    "dccdb953cdf32bea03f365760b0ed800" ++
    "2098d4ce20d045b45a83a8432cc73767" ++
    "7aed27125592a7148d25c87fdbe0a3f6";

fn hexBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}
