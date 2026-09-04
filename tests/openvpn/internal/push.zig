// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const logging = source.core_logging;
const push = source.openvpn_internal.push;

const CapturingLogger = struct {
    var message: [512]u8 = undefined;
    var message_len: usize = 0;

    fn log(_: ?*anyopaque, _: c_int, raw_message: [*:0]const u8) callconv(.c) void {
        const value = std.mem.span(raw_message);
        message_len = @min(value.len, message.len);
        @memcpy(message[0..message_len], value[0..message_len]);
    }

    fn lastMessage() []const u8 {
        return message[0..message_len];
    }
};

test "PUSH_REPLY without negotiated options preserves nil values" {
    var reply = (try push.PushReply.parse(
        std.testing.allocator,
        "PUSH_REPLY,redirect-gateway def1",
    )).?;
    defer reply.deinit(std.testing.allocator);
    try std.testing.expect(reply.options.cipher == null);
    try std.testing.expect(reply.options.digest == null);
    try std.testing.expect(reply.options.compression_framing == null);
    try std.testing.expect(reply.options.compression_algorithm == null);
}

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

test "PUSH_REPLY parses cipher and digest values case-insensitively" {
    var reply = (try push.PushReply.parse(
        std.testing.allocator,
        "PUSH_REPLY,cipher aEs-256-gCm,auth sHa384",
    )).?;
    defer reply.deinit(std.testing.allocator);

    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, reply.options.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha384, reply.options.digest.?);
}

test "PUSH_REPLY parses net30 gateways and DNS servers" {
    const allocator = std.testing.allocator;
    var reply = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,redirect-gateway def1,dhcp-option DNS 209.222.18.222,dhcp-option DNS 209.222.18.218,topology net30,ifconfig 10.5.10.6 10.5.10.5",
    )).?;
    defer reply.deinit(allocator);
    const subnet = reply.options.ipv4.?.subnets[0];
    try std.testing.expectEqualStrings("10.5.10.6", subnet.address.raw);
    try std.testing.expectEqual(@as(u8, 30), subnet.prefix_length);
    try std.testing.expectEqualStrings("10.5.10.5", reply.options.route_gateway4.?.raw);
    try std.testing.expectEqual(@as(usize, 2), reply.options.dns_servers.?.len);
    try std.testing.expectEqualStrings(
        "209.222.18.222",
        reply.options.dns_servers.?[0],
    );
    try std.testing.expectEqualStrings(
        "209.222.18.218",
        reply.options.dns_servers.?[1],
    );
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

test "PUSH_REPLY parses routes and IPv6 DNS" {
    const allocator = std.testing.allocator;
    var reply = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,dhcp-option DNS6 2001:4860:4860::8888,route 192.168.0.0 255.255.255.0 10.8.0.12,topology subnet,route-gateway 10.8.0.1,ifconfig 10.8.0.2 255.255.255.0,ifconfig-ipv6 fe80::601:30ff:feb7:ec01/64 fe80::601:30ff:feb7:dc02",
    )).?;
    defer reply.deinit(allocator);
    const route = reply.options.routes4.?[0];
    try std.testing.expectEqualStrings(
        "192.168.0.0",
        route.destination.?.address.raw,
    );
    try std.testing.expectEqual(@as(u8, 24), route.destination.?.prefix_length);
    try std.testing.expectEqualStrings("10.8.0.12", route.gateway.?.raw);
    try std.testing.expectEqualStrings(
        "fe80::601:30ff:feb7:ec01",
        reply.options.ipv6.?.subnets[0].address.raw,
    );
    try std.testing.expectEqualStrings(
        "2001:4860:4860::8888",
        reply.options.dns_servers.?[0],
    );
}

test "PUSH_REPLY ignores the remote host net gateway bypass route" {
    const allocator = std.testing.allocator;
    var reply = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,route-gateway 10.242.0.1,sndbuf 0,rcvbuf 0,ping 45,ping-restart 180,route 192.168.138.0 255.255.255.0,route 192.168.20.0 255.255.255.0,route 192.168.10.0 255.255.255.0,route 10.100.11.0 255.255.255.0,topology subnet,route remote_host 255.255.255.255 net_gateway,dhcp-option DNS 192.168.138.253,dhcp-option DOMAIN sos.lan,ifconfig 10.242.128.101 255.255.0.0,peer-id 1,cipher AES-256-GCM",
    )).?;
    defer reply.deinit(allocator);

    try std.testing.expectEqual(@as(?f64, 45), reply.options.keep_alive_interval);
    try std.testing.expectEqual(@as(?f64, 180), reply.options.keep_alive_timeout);
    try std.testing.expectEqualStrings("10.242.0.1", reply.options.route_gateway4.?.raw);
    try std.testing.expectEqualStrings(
        "10.242.128.101",
        reply.options.ipv4.?.subnets[0].address.raw,
    );
    try std.testing.expectEqual(@as(u8, 16), reply.options.ipv4.?.subnets[0].prefix_length);
    const expected_routes = [_][]const u8{
        "192.168.138.0",
        "192.168.20.0",
        "192.168.10.0",
        "10.100.11.0",
    };
    try std.testing.expectEqual(expected_routes.len, reply.options.routes4.?.len);
    for (expected_routes, reply.options.routes4.?) |expected, route| {
        try std.testing.expectEqualStrings(expected, route.destination.?.address.raw);
    }
    try std.testing.expectEqualStrings("192.168.138.253", reply.options.dns_servers.?[0]);
    try std.testing.expectEqualStrings("sos.lan", reply.options.dns_domain.?);
    try std.testing.expectEqual(@as(?u32, 1), reply.options.peer_id);
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, reply.options.cipher.?);
}

test "PUSH_REPLY validates compression framing and algorithms" {
    const allocator = std.testing.allocator;
    var lzo = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,comp-lzo no,cipher AES-256-CBC",
    )).?;
    defer lzo.deinit(allocator);
    try std.testing.expectEqual(
        api.OpenVPNCompressionFraming.compLZO,
        lzo.options.compression_framing.?,
    );
    try std.testing.expectEqual(
        api.OpenVPNCompressionAlgorithm.disabled,
        lzo.options.compression_algorithm.?,
    );

    var compress = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,compress,cipher AES-256-CBC",
    )).?;
    defer compress.deinit(allocator);
    try std.testing.expectEqual(
        api.OpenVPNCompressionFraming.compress,
        compress.options.compression_framing.?,
    );
    try std.testing.expectEqual(
        api.OpenVPNCompressionAlgorithm.disabled,
        compress.options.compression_algorithm.?,
    );

    try std.testing.expectError(
        error.UnsupportedCompression,
        push.PushReply.parse(allocator, "PUSH_REPLY,comp-lzo"),
    );
    try std.testing.expectError(
        error.UnsupportedCompression,
        push.PushReply.parse(allocator, "PUSH_REPLY,comp-lzo yes"),
    );
    try std.testing.expectError(
        error.UnsupportedCompression,
        push.PushReply.parse(allocator, "PUSH_REPLY,compress lz4"),
    );
}

test "PUSH_REPLY parses keepalive values and a trailing NCP cipher" {
    const allocator = std.testing.allocator;
    var reply = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,ping 10,ping-restart 60,cipher AES-256-GCM,auth-token",
    )).?;
    defer reply.deinit(allocator);
    try std.testing.expectEqual(@as(?f64, 10), reply.options.keep_alive_interval);
    try std.testing.expectEqual(@as(?f64, 60), reply.options.keep_alive_timeout);
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, reply.options.cipher.?);
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

test "writef formats PUSH_REPLY according to the private logging policy" {
    const allocator = std.testing.allocator;
    var reply = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,ping 10,auth-token somethingsecret,cipher AES-256-GCM",
    )).?;
    defer reply.deinit(allocator);
    logging.init(true, null, CapturingLogger.log);
    defer logging.deinit();

    logging.writef(.info, "{s}", .{reply});

    try std.testing.expectEqualStrings(
        "PUSH_REPLY,ping 10,auth-token somethingsecret,cipher AES-256-GCM",
        CapturingLogger.lastMessage(),
    );

    logging.init(false, null, CapturingLogger.log);
    logging.writef(.info, "{s}", .{reply});
    try std.testing.expectEqualStrings(
        "<redacted>",
        CapturingLogger.lastMessage(),
    );
}

test "PUSH_REPLY distinguishes a route gateway from redirect gateway policy" {
    const allocator = std.testing.allocator;
    var routed = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,route-gateway 10.8.0.1,topology subnet,ifconfig 10.8.0.2 255.255.255.0",
    )).?;
    defer routed.deinit(allocator);
    try std.testing.expect(routed.options.routing_policies == null);
    try std.testing.expectEqual(@as(usize, 1), routed.options.ipv4.?.included_routes.len);
    try std.testing.expectEqualStrings(
        "10.8.0.0",
        routed.options.ipv4.?.included_routes[0].destination.?.address.raw,
    );

    var redirected = (try push.PushReply.parse(
        allocator,
        "PUSH_REPLY,route-gateway 10.8.0.1,topology subnet,ifconfig 10.8.0.2 255.255.255.0,redirect-gateway def1,redirect-gateway bypass-dhcp",
    )).?;
    defer redirected.deinit(allocator);
    try std.testing.expectEqualSlices(
        api.OpenVPNRoutingPolicy,
        &.{.IPv4},
        redirected.options.routing_policies.?,
    );
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

test "peer info has one trailing newline" {
    const info = try push.testing.formatPeerInfo(
        std.testing.allocator,
        "test",
        "TLSv1.3",
        "linux",
        "6.1",
        &.{.aes256gcm},
    );
    defer std.testing.allocator.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "IV_MTU=1600\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, info, "IV_CIPHERS=AES-256-GCM\n"));
    try std.testing.expect(!std.mem.endsWith(u8, info, "\n\n"));
}
