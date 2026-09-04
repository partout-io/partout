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

    fn log(_: ?*anyopaque, _: c_int, raw_message: [*:0]const u8) callconv(.c) void {
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

    fn log(_: ?*anyopaque, _: c_int, _: [*:0]const u8) callconv(.c) void {
        called = true;
    }
};

const ProfileLogger = struct {
    var saw_id = false;
    var saw_name = false;
    var saw_header = false;
    var saw_inactive_wireguard = false;
    var saw_active_on_demand = false;

    fn reset() void {
        saw_id = false;
        saw_name = false;
        saw_header = false;
        saw_inactive_wireguard = false;
        saw_active_on_demand = false;
    }

    fn log(_: ?*anyopaque, _: c_int, raw_message: [*:0]const u8) callconv(.c) void {
        const message = std.mem.span(raw_message);
        saw_id = saw_id or std.mem.eql(
            u8,
            message,
            "\tID: 00000000-0000-0000-0000-000000000000",
        );
        saw_name = saw_name or std.mem.eql(u8, message, "\tName: Test profile");
        saw_header = saw_header or std.mem.eql(u8, message, "\tModules:");
        saw_inactive_wireguard = saw_inactive_wireguard or std.mem.eql(
            u8,
            message,
            "\t\t- WireGuardModule: <redacted>",
        );
        saw_active_on_demand = saw_active_on_demand or std.mem.eql(
            u8,
            message,
            "\t\t+ OnDemandModule: <redacted>",
        );
    }
};

const ReconfiguringValue = struct {
    pub fn logging_formatter(
        allocator: std.mem.Allocator,
        _: ReconfiguringValue,
    ) ![]const u8 {
        logging.init(false, null, ReplacementLogger.log);
        return allocator.dupe(u8, "secret");
    }
};

test "private data flag round-trips" {
    logging.init(true, null, null);
    defer logging.deinit();
    try std.testing.expect(logging.logsPrivateData());
}

test "logging is disabled without callback" {
    logging.init(false, null, null);
    defer logging.deinit();
    try std.testing.expect(!logging.hasLogger());
    logging.write(.notice, "ignored");
}

test "external logger callback receives context and log messages" {
    const TestLogger = struct {
        var called = false;
        var saw_level = false;
        var saw_message = false;

        fn log(ctx: ?*anyopaque, level: c_int, message: [*:0]const u8) callconv(.c) void {
            called = true;
            const saw_context: *bool = @ptrCast(@alignCast(ctx.?));
            saw_context.* = true;
            saw_level = level == @intFromEnum(logging.Level.notice);
            saw_message = std.mem.eql(u8, std.mem.span(message), "hello");
        }
    };

    var saw_context = false;
    logging.init(false, &saw_context, TestLogger.log);
    defer logging.deinit();

    logging.write(.notice, "hello");

    try std.testing.expect(TestLogger.called);
    try std.testing.expect(saw_context);
    try std.testing.expect(TestLogger.saw_level);
    try std.testing.expect(TestLogger.saw_message);
}

test "profile modules log active and inactive prefixes" {
    ProfileLogger.reset();
    logging.init(false, null, ProfileLogger.log);
    defer logging.deinit();

    const wireguard_id = api.UUID{
        '1', '1', '1', '1', '1', '1', '1', '1', '-',
        '1', '1', '1', '1', '-', '4', '1', '1', '1',
        '-', '8', '1', '1', '1', '-', '1', '1', '1',
        '1', '1', '1', '1', '1', '1', '1', '1', '1',
    };
    const on_demand_id = api.UUID{
        '2', '2', '2', '2', '2', '2', '2', '2', '-',
        '2', '2', '2', '2', '-', '4', '2', '2', '2',
        '-', '8', '2', '2', '2', '-', '2', '2', '2',
        '2', '2', '2', '2', '2', '2', '2', '2', '2',
    };
    const modules = [_]api.TaggedModule{
        .{ .WireGuard = .{ .id = wireguard_id } },
        .{ .OnDemand = .{ .id = on_demand_id, .policy = .any } },
    };
    const active_modules_ids = [_]api.UUID{on_demand_id};
    const profile = api.Profile{
        .name = "Test profile",
        .modules = &modules,
        .active_modules_ids = &active_modules_ids,
    };

    logging.writeProfile(.notice, &profile);

    try std.testing.expect(ProfileLogger.saw_id);
    try std.testing.expect(ProfileLogger.saw_name);
    try std.testing.expect(ProfileLogger.saw_header);
    try std.testing.expect(ProfileLogger.saw_inactive_wireguard);
    try std.testing.expect(ProfileLogger.saw_active_on_demand);
}

test "sentinel log messages cross the C callback without copying" {
    const TestLogger = struct {
        var message_address: usize = 0;

        fn log(_: ?*anyopaque, _: c_int, message: [*:0]const u8) callconv(.c) void {
            message_address = @intFromPtr(message);
        }
    };

    const message: [:0]const u8 = "borrowed";
    logging.init(false, null, TestLogger.log);
    defer logging.deinit();

    logging.write(.notice, message);

    try std.testing.expectEqual(@intFromPtr(message.ptr), TestLogger.message_address);
}

test "C log messages are forwarded without scanning or copying" {
    const TestLogger = struct {
        var message_address: usize = 0;

        fn log(_: ?*anyopaque, _: c_int, message: [*:0]const u8) callconv(.c) void {
            message_address = @intFromPtr(message);
        }
    };

    const message: [:0]const u8 = "borrowed";
    logging.init(false, null, TestLogger.log);
    defer logging.deinit();

    logging.writeCString(.notice, message.ptr);

    try std.testing.expectEqual(@intFromPtr(message.ptr), TestLogger.message_address);
}

test "duration helpers log compact time representations" {
    CapturingLogger.reset();
    logging.init(false, null, CapturingLogger.log);
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
    logging.init(false, null, CapturingLogger.log);
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

    logging.init(true, null, CapturingLogger.log);
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
    logging.init(true, null, CapturingLogger.log);
    defer logging.deinit();

    const marked_while_private = logging.sensitive("example.com");
    logging.init(false, null, CapturingLogger.log);
    logging.writef(.debug, "DNS resolved {s}", .{marked_while_private});
    try std.testing.expectEqualStrings(
        "DNS resolved <redacted>",
        CapturingLogger.lastMessage(),
    );

    const marked_while_redacted = logging.sensitive("example.com");
    logging.init(true, null, CapturingLogger.log);
    logging.writef(.debug, "DNS resolved {s}", .{marked_while_redacted});
    try std.testing.expectEqualStrings(
        "DNS resolved example.com",
        CapturingLogger.lastMessage(),
    );
}

test "writef dispatches with the same state used to prepare arguments" {
    CapturingLogger.reset();
    ReplacementLogger.reset();
    logging.init(true, null, CapturingLogger.log);
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
    logging.init(true, null, CapturingLogger.log);
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

    logging.init(false, null, CapturingLogger.log);
    logging.writef(.notice, "Array: {s}", .{&endpoints});
    try std.testing.expectEqualStrings(
        "Array: <redacted>",
        CapturingLogger.lastMessage(),
    );
}

test "writef recognizes generated sensitive models without generated methods" {
    CapturingLogger.reset();
    logging.init(true, null, CapturingLogger.log);
    defer logging.deinit();

    const subnets = [_]api.Subnet{api.Subnet.parseRaw("10.0.0.2/24").?};
    const settings = api.IPSettings{ .subnets = &subnets };
    logging.writef(.notice, "Settings: {s}", .{settings});
    try std.testing.expectEqualStrings(
        "Settings: addrs [10.0.0.2/24], includedRoutes=[], excludedRoutes=[]",
        CapturingLogger.lastMessage(),
    );

    logging.init(false, null, CapturingLogger.log);
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

    logging.init(true, null, CapturingLogger.log);
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
