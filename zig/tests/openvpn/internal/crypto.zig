// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const crypto = source.openvpn_internal.crypto;

const static_key_content_length = 256;
const static_key_length = 64;

test "client and server tls-crypt keys are complementary" {
    var bytes: [static_key_content_length]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var secure = try api.SecureData.initBytesAlloc(std.testing.allocator, &bytes);
    defer secure.deinit(std.testing.allocator);
    var client = try crypto.cryptKeys(std.testing.allocator, .{ .data = secure, .dir = .client });
    defer client.deinit(std.testing.allocator);
    var server = try crypto.cryptKeys(std.testing.allocator, .{ .data = secure, .dir = .server });
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

test "PIA payload prepends the repeating XOR key" {
    const Fixed = struct {
        fn fill(_: ?*anyopaque, destination: []u8) bool {
            for (destination, 0..) |*byte, index| byte.* = @intCast(index + 1);
            return true;
        }
    };
    const value = crypto.PIAHardReset.init("012345", .aes128cbc, .sha1);
    const encoded = try value.encodedData(
        std.testing.allocator,
        .{ .fill_fn = Fixed.fill },
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, encoded[0..3]);
    try std.testing.expectEqual(@as(u8, crypto.PIAHardReset.magic[0] ^ 1), encoded[3]);
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
    var keys = try crypto.authKeys(std.testing.allocator, .{ .data = secure, .dir = null });
    defer keys.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.encryption_key.bytes, 1));
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.decryption_key.bytes, 1));
}

test "ZeroingData delegates append and slice to pp_zd" {
    const allocator = std.testing.allocator;
    var data = try crypto.ZeroingData.initCopy(allocator, "abc");
    defer data.deinit(allocator);
    try data.append(allocator, "def");
    try std.testing.expectEqualStrings("abcdef", data.bytes);

    var part = try data.sliceCopy(allocator, 2, 3);
    defer part.deinit(allocator);
    try std.testing.expectEqualStrings("cde", part.bytes);
}
