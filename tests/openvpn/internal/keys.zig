// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const keys = source.openvpn_internal.keys;

const StaticKey = keys.StaticKey;

const static_key_content_length = 256;
const static_key_length = 64;

test "static key exposes the Swift API" {
    var bytes: [static_key_content_length]u8 = undefined;
    for (0..4) |quadrant_index| {
        @memset(
            bytes[quadrant_index * static_key_length .. (quadrant_index + 1) * static_key_length],
            @intCast(quadrant_index),
        );
    }
    var secure = try api.SecureData.initBytesAlloc(std.testing.allocator, &bytes);
    defer secure.deinit(std.testing.allocator);

    var server = try StaticKey.init(std.testing.allocator, .{ .data = secure, .dir = .server });
    defer server.deinit();
    try std.testing.expect(std.mem.allEqual(u8, try server.cipherEncryptKey(), 0));
    try std.testing.expect(std.mem.allEqual(u8, try server.cipherDecryptKey(), 2));
    try std.testing.expect(std.mem.allEqual(u8, server.hmacSendKey(), 1));
    try std.testing.expect(std.mem.allEqual(u8, server.hmacReceiveKey(), 3));

    var client = try StaticKey.init(std.testing.allocator, .{ .data = secure, .dir = .client });
    defer client.deinit();
    try std.testing.expect(std.mem.allEqual(u8, try client.cipherEncryptKey(), 2));
    try std.testing.expect(std.mem.allEqual(u8, try client.cipherDecryptKey(), 0));
    try std.testing.expect(std.mem.allEqual(u8, client.hmacSendKey(), 3));
    try std.testing.expect(std.mem.allEqual(u8, client.hmacReceiveKey(), 1));

    const hex = try client.hexStringAlloc(std.testing.allocator);
    defer std.testing.allocator.free(hex);
    try std.testing.expectEqual(@as(usize, 512), hex.len);
    try std.testing.expect(std.mem.startsWith(u8, hex, "00000000000000000000000000000000"));

    const file_contents = try client.fileContentsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(file_contents);
    try std.testing.expect(std.mem.startsWith(
        u8,
        file_contents,
        "# 2048 bit OpenVPN static key\n-----BEGIN OpenVPN Static key V1-----\n",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        file_contents,
        "-----END OpenVPN Static key V1-----",
    ));

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    var line_iterator = std.mem.splitScalar(u8, file_contents, '\n');
    while (line_iterator.next()) |line| try lines.append(std.testing.allocator, line);
    var parsed = try StaticKey.parseFileAlloc(std.testing.allocator, lines.items, .server);
    defer parsed.deinit(std.testing.allocator);
    const parsed_bytes = try parsed.data.bytesAlloc(std.testing.allocator);
    defer std.testing.allocator.free(parsed_bytes);
    try std.testing.expectEqualSlices(u8, &bytes, parsed_bytes);
    try std.testing.expectEqual(api.OpenVPNStaticKeyDirection.server, parsed.dir.?);

    var bidirectional = try StaticKey.init(std.testing.allocator, .{ .data = secure });
    defer bidirectional.deinit();
    try std.testing.expectError(error.MissingStaticKeyDirection, bidirectional.cipherEncryptKey());
    try std.testing.expectError(error.MissingStaticKeyDirection, bidirectional.cipherDecryptKey());
    try std.testing.expect(std.mem.allEqual(u8, bidirectional.hmacSendKey(), 1));
    try std.testing.expect(std.mem.allEqual(u8, bidirectional.hmacReceiveKey(), 1));
}
