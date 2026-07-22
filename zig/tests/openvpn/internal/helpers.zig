// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const helpers = source.openvpn_internal.helpers;

const static_key_content_length = 256;
const static_key_length = 64;

test "BidirectionalState resets both directions" {
    var state = helpers.BidirectionalState(u32).init(7);
    state.inbound = 1;
    state.outbound = 2;
    state.reset();
    try std.testing.expectEqual(@as(u32, 7), state.inbound);
    try std.testing.expectEqual(@as(u32, 7), state.outbound);
}

test "client and server tls-crypt keys are complementary" {
    var bytes: [static_key_content_length]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var secure = try api.SecureData.initBytesAlloc(std.testing.allocator, &bytes);
    defer secure.deinit(std.testing.allocator);
    var client = try helpers.cryptKeys(std.testing.allocator, .{ .data = secure, .dir = .client });
    defer client.deinit(std.testing.allocator);
    var server = try helpers.cryptKeys(std.testing.allocator, .{ .data = secure, .dir = .server });
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

test "forAuthentication appends and encodes OTP" {
    const allocator = std.testing.allocator;

    var appended = try helpers.forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .append,
        .otp = "123",
    });
    defer appended.deinit(allocator);
    try std.testing.expectEqualStrings("pass123", appended.password);

    var encoded = try helpers.forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .encode,
        .otp = "123",
    });
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings("SCRV1:cGFzcw==:MTIz", encoded.password);
}

test "PIA payload prepends the repeating XOR key" {
    const Fixed = struct {
        fn fill(_: ?*anyopaque, destination: []u8) bool {
            for (destination, 0..) |*byte, index| byte.* = @intCast(index + 1);
            return true;
        }
    };
    const value = helpers.PIAHardReset.init("012345", .aes128cbc, .sha1);
    const encoded = try value.encodedData(
        std.testing.allocator,
        .{ .fill_fn = Fixed.fill },
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, encoded[0..3]);
    try std.testing.expectEqual(@as(u8, helpers.PIAHardReset.magic[0] ^ 1), encoded[3]);
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
    var keys = try helpers.authKeys(std.testing.allocator, .{ .data = secure, .dir = null });
    defer keys.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.encryption_key.bytes, 1));
    try std.testing.expect(std.mem.allEqual(u8, keys.digest.?.decryption_key.bytes, 1));
}
