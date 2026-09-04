// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const logging = source.core_logging;
const openvpn_logging = source.openvpn_internal.logging;

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

test "pushReplyString redacts auth tokens unless private logging is enabled" {
    const allocator = std.testing.allocator;
    const message = "PUSH_REPLY,ping 10,auth-token somethingsecret,cipher AES-256-GCM";
    logging.init(false, null, null);
    defer logging.deinit();

    const loggable = try openvpn_logging.pushReplyString(allocator, message);
    defer allocator.free(loggable);
    try std.testing.expectEqualStrings(
        "PUSH_REPLY,ping 10,auth-token <redacted>,cipher AES-256-GCM",
        loggable,
    );

    logging.init(true, null, null);
    const private_loggable = try openvpn_logging.pushReplyString(allocator, message);
    defer allocator.free(private_loggable);
    try std.testing.expectEqualStrings(message, private_loggable);
}

test "logConfiguration accepts empty sensitive strings" {
    const configuration = api.OpenVPNConfiguration{
        .checks_san_host = true,
        .san_host = "",
        .dns_domain = "",
        .proxy_auto_configuration_url = "",
    };
    logging.init(false, null, null);
    defer logging.deinit();

    openvpn_logging.logConfiguration(&configuration, true);
}

test "logConfiguration formats route collections as strings" {
    const routes = [_]api.Route{
        .{ .destination = api.Subnet.parseRaw("10.0.0.0/24").? },
    };
    const configuration = api.OpenVPNConfiguration{ .routes4 = &routes };
    logging.init(false, null, CapturingLogger.log);
    defer logging.deinit();

    openvpn_logging.logConfiguration(&configuration, false);
    try std.testing.expectEqualStrings(
        "\tRoutes (IPv4): <redacted>",
        CapturingLogger.lastMessage(),
    );

    logging.init(true, null, CapturingLogger.log);
    openvpn_logging.logConfiguration(&configuration, false);
    try std.testing.expectEqualStrings(
        "\tRoutes (IPv4): [{\"destination\":\"10.0.0.0/24\"}]",
        CapturingLogger.lastMessage(),
    );
}
