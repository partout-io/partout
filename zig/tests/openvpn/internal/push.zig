// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const push = source.openvpn_internal.push;

test "PUSH_REPLY parses through the standard OpenVPN parser" {
    var reply = (try push.PushReply.parse(
        std.testing.allocator,
        "PUSH_REPLY,ping 10,ping-restart 60,cipher AES-256-GCM,auth SHA256,peer-id 7",
    )).?;
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?f64, 10), reply.options.keep_alive_interval);
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, reply.options.cipher.?);
    try std.testing.expectEqual(@as(?u32, 7), reply.options.peer_id);
}

test "PUSH_REPLY parses pushed tunnel addresses" {
    const allocator = std.testing.allocator;
    var reply = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,topology subnet,ifconfig 10.9.0.7 255.255.255.0,route-gateway 10.9.0.1,ifconfig-ipv6 fd00:9::7/64 fd00:9::1",
    )).?;
    defer reply.deinit(allocator);

    try std.testing.expectEqualStrings(
        "10.9.0.7",
        reply.options.ipv4.?.subnets[0].address.raw,
    );
    try std.testing.expectEqualStrings(
        "fd00:9::7",
        reply.options.ipv6.?.subnets[0].address.raw,
    );
}

test "PUSH_REPLY ignores incomplete ifconfig like the Swift parser" {
    const allocator = std.testing.allocator;
    var reply = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,ifconfig 10.8.0.2,auth-token somethingsecret,cipher AES-128-CBC",
    )).?;
    defer reply.deinit(allocator);

    try std.testing.expect(reply.options.ipv4 == null);
    try std.testing.expectEqual(api.OpenVPNCipher.aes128cbc, reply.options.cipher.?);
}

test "PUSH_REPLY clone owns independent storage" {
    var reply = (try push.PushReply.parse(std.testing.allocator, "PUSH_REPLY,ping 10")).?;
    defer reply.deinit(std.testing.allocator);
    var copy = try reply.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(reply.original, copy.original);
    try std.testing.expect(reply.original.ptr != copy.original.ptr);
}

test "PUSH_REPLY signals a continuation fragment" {
    try std.testing.expectError(
        error.ContinuationPushReply,
        push.PushReply.parse(
            std.testing.allocator,
            "PUSH_REPLY,route 10.0.0.0 255.0.0.0,push-continuation 2",
        ),
    );
}

test "runtime platform version has major and minor components" {
    const version = try push.testing.platformVersion(std.testing.allocator);
    defer std.testing.allocator.free(version);
    const separator = std.mem.indexOfScalar(u8, version, '.') orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(separator > 0);
    try std.testing.expect(separator + 1 < version.len);
}

test "peer info has one trailing newline" {
    const info = try push.testing.formatPeerInfo(
        std.testing.allocator,
        "test",
        "TLSv1.3",
        "linux",
        "6.1",
        &.{"IV_CIPHERS=AES-256-GCM"},
    );
    defer std.testing.allocator.free(info);
    try std.testing.expect(std.mem.endsWith(u8, info, "IV_CIPHERS=AES-256-GCM\n"));
    try std.testing.expect(!std.mem.endsWith(u8, info, "\n\n"));
}
