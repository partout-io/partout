// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! OpenVPN static-key quadrant extraction shared by control serializers.

const std = @import("std");

const api = @import("../../core/exports.zig").api;
const CryptoKeyPair = @import("crypto_key_pair.zig").CryptoKeyPair;
const CryptoKeys = @import("crypto_keys.zig").CryptoKeys;
const errors = @import("errors.zig");
const ZeroingData = @import("zeroing_data.zig").ZeroingData;

const content_length = 256;
const key_length = 64;

pub const Error = errors.StaticKeyError;

pub fn authKeys(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) Error!CryptoKeys {
    const bytes = try decode(allocator, key);
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
    var send = try ZeroingData.initCopy(allocator, quadrant(bytes, send_index));
    errdefer send.deinit(allocator);
    const receive = try ZeroingData.initCopy(allocator, quadrant(bytes, receive_index));
    return CryptoKeys.init(null, CryptoKeyPair.init(send, receive));
}

pub fn cryptKeys(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) Error!CryptoKeys {
    const direction = key.dir orelse return error.MissingStaticKeyDirection;
    const bytes = try decode(allocator, key);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    const cipher_send_index: usize = if (direction == .server) 0 else 2;
    const cipher_receive_index: usize = if (direction == .server) 2 else 0;
    const hmac_send_index: usize = if (direction == .server) 1 else 3;
    const hmac_receive_index: usize = if (direction == .server) 3 else 1;

    var cipher_send = try ZeroingData.initCopy(allocator, quadrant(bytes, cipher_send_index));
    errdefer cipher_send.deinit(allocator);
    var cipher_receive = try ZeroingData.initCopy(allocator, quadrant(bytes, cipher_receive_index));
    errdefer cipher_receive.deinit(allocator);
    var hmac_send = try ZeroingData.initCopy(allocator, quadrant(bytes, hmac_send_index));
    errdefer hmac_send.deinit(allocator);
    const hmac_receive = try ZeroingData.initCopy(allocator, quadrant(bytes, hmac_receive_index));
    return CryptoKeys.init(
        CryptoKeyPair.init(cipher_send, cipher_receive),
        CryptoKeyPair.init(hmac_send, hmac_receive),
    );
}

fn decode(allocator: std.mem.Allocator, key: api.OpenVPNStaticKey) Error![]u8 {
    const bytes = try key.data.bytesAlloc(allocator);
    errdefer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    if (bytes.len != content_length) return error.InvalidStaticKey;
    return bytes;
}

fn quadrant(bytes: []const u8, index: usize) []const u8 {
    return bytes[index * key_length .. (index + 1) * key_length];
}

test "client and server tls-crypt keys are complementary" {
    var bytes: [content_length]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var secure = try api.SecureData.initBytesAlloc(std.testing.allocator, &bytes);
    defer secure.deinit(std.testing.allocator);
    var client = try cryptKeys(std.testing.allocator, .{ .data = secure, .dir = .client });
    defer client.deinit(std.testing.allocator);
    var server = try cryptKeys(std.testing.allocator, .{ .data = secure, .dir = .server });
    defer server.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        client.cipher.?.encryption_key.bytes,
        server.cipher.?.decryption_key.bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        client.digest.?.encryption_key.bytes,
        server.digest.?.decryption_key.bytes,
    );
}

test "tls-auth without key direction uses the shared HMAC quadrant" {
    var bytes: [content_length]u8 = undefined;
    for (0..4) |quadrant_index| {
        @memset(
            bytes[quadrant_index * key_length .. (quadrant_index + 1) * key_length],
            @as(u8, @intCast(quadrant_index)),
        );
    }
    var secure = try api.SecureData.initBytesAlloc(std.testing.allocator, &bytes);
    defer secure.deinit(std.testing.allocator);
    var keys = try authKeys(std.testing.allocator, .{ .data = secure, .dir = null });
    defer keys.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.encryption_key.bytes, 1));
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.decryption_key.bytes, 1));
}
