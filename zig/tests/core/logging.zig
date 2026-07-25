// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("source").core_api;
const logging = @import("source").core_logging;

const CapturingLogger = struct {
    var message: [256]u8 = undefined;
    var message_len: usize = 0;

    fn reset() void {
        message_len = 0;
    }

    fn log(_: c_int, raw_message: [*:0]const u8) callconv(.c) void {
        const value = std.mem.span(raw_message);
        message_len = @min(value.len, message.len);
        @memcpy(message[0..message_len], value[0..message_len]);
    }

    fn lastMessage() []const u8 {
        return message[0..message_len];
    }
};

const ReplacementLogger = struct {
    var called = false;

    fn reset() void {
        called = false;
    }

    fn log(_: c_int, _: [*:0]const u8) callconv(.c) void {
        called = true;
    }
};

const ReconfiguringValue = struct {
    pub fn logging_formatter(
        allocator: std.mem.Allocator,
        _: ReconfiguringValue,
    ) ![]const u8 {
        logging.init(false, ReplacementLogger.log);
        return allocator.dupe(u8, "secret");
    }
};

test "private data flag round-trips" {
    logging.init(true, null);
    defer logging.deinit();
    try std.testing.expect(logging.logsPrivateData());
}

test "logging is disabled without callback" {
    logging.init(false, null);
    defer logging.deinit();
    try std.testing.expect(!logging.hasLogger());
    logging.write(.notice, "ignored");
}

test "external logger callback receives log messages" {
    const TestLogger = struct {
        var called = false;
        var saw_level = false;
        var saw_message = false;

        fn log(level: c_int, message: [*:0]const u8) callconv(.c) void {
            called = true;
            saw_level = level == @intFromEnum(logging.Level.notice);
            saw_message = std.mem.eql(u8, std.mem.span(message), "hello");
        }
    };

    logging.init(false, TestLogger.log);
    defer logging.deinit();

    logging.write(.notice, "hello");

    try std.testing.expect(TestLogger.called);
    try std.testing.expect(TestLogger.saw_level);
    try std.testing.expect(TestLogger.saw_message);
}

test "duration helpers log compact time representations" {
    CapturingLogger.reset();
    logging.init(false, CapturingLogger.log);
    defer logging.deinit();

    logging.logTimeSeconds(.debug, "Elapsed: ", 3661);
    try std.testing.expectEqualStrings(
        "Elapsed: 1h1m1s",
        CapturingLogger.lastMessage(),
    );

    logging.logTimeMs(.debug, "Delay: ", 120_000);
    try std.testing.expectEqualStrings(
        "Delay: 2m",
        CapturingLogger.lastMessage(),
    );
}

test "writef automatically redacts registered argument types" {
    CapturingLogger.reset();
    logging.init(false, CapturingLogger.log);
    defer logging.deinit();

    const endpoint = api.Endpoint{
        .address = "example.com",
        .port = 443,
    };
    logging.writef(.notice, "Public: {d}, endpoint: {s}", .{
        42,
        endpoint,
    });
    try std.testing.expectEqualStrings(
        "Public: 42, endpoint: <redacted>",
        CapturingLogger.lastMessage(),
    );

    const address = api.Address.parseRaw("192.0.2.1").?;
    logging.writef(.debug, "DNS64: mapped {s} to itself.", .{address});
    try std.testing.expectEqualStrings(
        "DNS64: mapped <redacted> to itself.",
        CapturingLogger.lastMessage(),
    );

    logging.writef(.debug, "DNS resolved {s}", .{
        logging.sensitive("example.com"),
    });
    try std.testing.expectEqualStrings(
        "DNS resolved <redacted>",
        CapturingLogger.lastMessage(),
    );

    logging.writef(.debug, "Sensitive number: {s}", .{
        logging.sensitive(@as(u16, 42)),
    });
    try std.testing.expectEqualStrings(
        "Sensitive number: <redacted>",
        CapturingLogger.lastMessage(),
    );

    logging.init(true, CapturingLogger.log);
    logging.writef(.notice, "Public: {d}, endpoint: {s}", .{
        42,
        endpoint,
    });
    try std.testing.expectEqualStrings(
        "Public: 42, endpoint: example.com:443",
        CapturingLogger.lastMessage(),
    );

    logging.writef(.debug, "DNS resolved {s}", .{
        logging.sensitive("example.com"),
    });
    try std.testing.expectEqualStrings(
        "DNS resolved example.com",
        CapturingLogger.lastMessage(),
    );

    logging.writef(.debug, "Sensitive number: {s}", .{
        logging.sensitive(@as(u16, 42)),
    });
    try std.testing.expectEqualStrings(
        "Sensitive number: 42",
        CapturingLogger.lastMessage(),
    );
}

test "sensitive values use the policy captured by writef" {
    CapturingLogger.reset();
    logging.init(true, CapturingLogger.log);
    defer logging.deinit();

    const marked_while_private = logging.sensitive("example.com");
    logging.init(false, CapturingLogger.log);
    logging.writef(.debug, "DNS resolved {s}", .{marked_while_private});
    try std.testing.expectEqualStrings(
        "DNS resolved <redacted>",
        CapturingLogger.lastMessage(),
    );

    const marked_while_redacted = logging.sensitive("example.com");
    logging.init(true, CapturingLogger.log);
    logging.writef(.debug, "DNS resolved {s}", .{marked_while_redacted});
    try std.testing.expectEqualStrings(
        "DNS resolved example.com",
        CapturingLogger.lastMessage(),
    );
}

test "writef dispatches with the same state used to prepare arguments" {
    CapturingLogger.reset();
    ReplacementLogger.reset();
    logging.init(true, CapturingLogger.log);
    defer logging.deinit();

    logging.writef(.debug, "{s}", .{ReconfiguringValue{}});

    try std.testing.expectEqualStrings(
        "secret",
        CapturingLogger.lastMessage(),
    );
    try std.testing.expect(!ReplacementLogger.called);
}

test "writef infers array and dictionary debug representations" {
    CapturingLogger.reset();
    logging.init(true, CapturingLogger.log);
    defer logging.deinit();

    const endpoints = [_]api.Endpoint{
        .{ .address = "alpha.example", .port = 1 },
        .{ .address = "beta.example", .port = 2 },
    };
    logging.writef(.notice, "Array: {s}", .{&endpoints});
    try std.testing.expectEqualStrings(
        "Array: [alpha.example:1, beta.example:2]",
        CapturingLogger.lastMessage(),
    );

    var dictionary = std.StringHashMap(api.Endpoint).init(std.testing.allocator);
    defer dictionary.deinit();
    try dictionary.put("key", .{ .address = "value.example", .port = 3 });
    logging.writef(.notice, "Dictionary: {s}", .{&dictionary});
    try std.testing.expectEqualStrings(
        "Dictionary: [key: value.example:3]",
        CapturingLogger.lastMessage(),
    );

    const addresses = [_]api.Address{
        api.Address.parseRaw("one.example").?,
        api.Address.parseRaw("two.example").?,
    };
    logging.writef(.notice, "Addresses: {s}", .{&addresses});
    try std.testing.expectEqualStrings(
        "Addresses: [one.example, two.example]",
        CapturingLogger.lastMessage(),
    );

    logging.init(false, CapturingLogger.log);
    logging.writef(.notice, "Array: {s}", .{&endpoints});
    try std.testing.expectEqualStrings(
        "Array: <redacted>",
        CapturingLogger.lastMessage(),
    );
}

test "writef recognizes generated sensitive models without generated methods" {
    CapturingLogger.reset();
    logging.init(true, CapturingLogger.log);
    defer logging.deinit();

    const subnets = [_]api.Subnet{api.Subnet.parseRaw("10.0.0.2/24").?};
    const settings = api.IPSettings{ .subnets = &subnets };
    logging.writef(.notice, "Settings: {s}", .{settings});
    try std.testing.expectEqualStrings(
        "Settings: addrs [10.0.0.2/24], includedRoutes=[], excludedRoutes=[]",
        CapturingLogger.lastMessage(),
    );

    logging.init(false, CapturingLogger.log);
    logging.writef(.notice, "Settings: {s}", .{settings});
    try std.testing.expectEqualStrings(
        "Settings: <redacted>",
        CapturingLogger.lastMessage(),
    );

    const credentials = api.OpenVPNCredentials{
        .username = "alice",
        .password = "secret",
        .otp_method = .none,
    };
    logging.writef(.notice, "Credentials: {s}", .{credentials});
    try std.testing.expectEqualStrings(
        "Credentials: <redacted>",
        CapturingLogger.lastMessage(),
    );

    logging.init(true, CapturingLogger.log);
    logging.writef(.notice, "Credentials: {s}", .{credentials});
    try std.testing.expect(std.mem.indexOf(
        u8,
        CapturingLogger.lastMessage(),
        "\"password\":\"secret\"",
    ) != null);

    const module = api.TaggedModule{ .DNS = .{} };
    logging.writef(.notice, "Module: {s}", .{module});
    try std.testing.expect(std.mem.startsWith(
        u8,
        CapturingLogger.lastMessage(),
        "Module: {\"type\":\"DNS\"",
    ));
}
