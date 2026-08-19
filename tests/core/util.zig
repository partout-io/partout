// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const util = @import("source").core.util;

test "parses JSON without coercing numbers" {
    const allocator = std.testing.allocator;
    var parsed = try util.parseJsonValue(allocator,
        \\{"name":"profile","count":42,"enabled":true}
    );
    defer parsed.deinit();

    const object = parsed.value.object;
    try std.testing.expectEqualStrings("profile", object.get("name").?.string);
    try std.testing.expectEqualStrings("42", object.get("count").?.number_string);
    try std.testing.expect(object.get("enabled").?.bool);
}

test "rejects invalid JSON" {
    try std.testing.expectError(
        error.InvalidJson,
        util.parseJsonValue(std.testing.allocator, "{\"broken\""),
    );
}

test "propagates JSON parser OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        util.parseJsonValue(failing.allocator(), "{\"name\":\"profile\"}"),
    );
    try std.testing.expect(failing.has_induced_failure);
}

test "encodes JSON values" {
    const allocator = std.testing.allocator;
    const encoded = try util.encodeJsonValue(allocator, .{
        .name = "profile",
        .count = @as(u8, 2),
    });
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("{\"name\":\"profile\",\"count\":2}", encoded);
}

test "encodes JSON values as null-terminated buffers" {
    const allocator = std.testing.allocator;
    const encoded = try util.encodeJsonValueZ(allocator, .{
        .name = "profile",
        .count = @as(u8, 2),
    });
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("{\"name\":\"profile\",\"count\":2}", encoded);
    try std.testing.expectEqual(@as(u8, 0), encoded[encoded.len]);
}

test "temporary C string copies and terminates values" {
    const allocator = std.testing.allocator;
    var original = [_]u8{ 'a', 'l', 'p', 'h', 'a' };

    var c_value: util.TemporaryCString = .{};
    try c_value.init(allocator, original[0..]);
    defer c_value.deinit();

    original[0] = 'A';
    try std.testing.expectEqualStrings("alpha", std.mem.span(c_value.ptr()));
    try std.testing.expectEqual(@as(u8, 0), c_value.slice()[c_value.slice().len]);
}

test "temporary C string uses stack storage before fallback allocator" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    var c_value: util.TemporaryCStringWithCapacity(8) = .{};
    try c_value.init(failing.allocator(), "small");
    defer c_value.deinit();

    try std.testing.expectEqualStrings("small", std.mem.span(c_value.ptr()));
    try std.testing.expect(!failing.has_induced_failure);
}

test "temporary C string reports fallback allocator failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    var c_value: util.TemporaryCStringWithCapacity(4) = .{};
    try std.testing.expectError(error.OutOfMemory, c_value.init(failing.allocator(), "large"));
    try std.testing.expect(failing.has_induced_failure);
}

test "passes sentinel slices to C callbacks without copying" {
    const Callback = struct {
        fn call(ctx: ?*anyopaque, value: [*c]const u8) callconv(.c) void {
            const seen: *?[*c]const u8 = @ptrCast(@alignCast(ctx.?));
            seen.* = value;
        }
    };

    const value: [:0]const u8 = "alpha";
    var seen: ?[*c]const u8 = null;
    util.withCString(value, Callback.call, &seen);

    try std.testing.expectEqual(@intFromPtr(value.ptr), @intFromPtr(seen.?));
}

test "borrows C strings without dropping sentinel metadata" {
    const value: [:0]const u8 = "alpha";
    const borrowed = util.borrowedCString(value.ptr);

    try std.testing.expectEqual(@intFromPtr(value.ptr), @intFromPtr(borrowed.ptr));
    try std.testing.expectEqual(@as(u8, 0), borrowed[borrowed.len]);
}

test "trims common ASCII whitespace" {
    try std.testing.expectEqualStrings("hello", util.trim(" \r\t\nhello \n\t"));
    try std.testing.expectEqualStrings("", util.trim(" \r\t\n"));
}

test "checks byte allow-lists" {
    try std.testing.expect(util.containsOnly("", ""));
    try std.testing.expect(util.containsOnly("cab", "abc"));
    try std.testing.expect(!util.containsOnly("cad", "abc"));
}

test "returns owned default cache directory" {
    const allocator = std.testing.allocator;
    const cache_dir = try util.defaultCacheDir(allocator);
    defer allocator.free(cache_dir);

    const env_names = [_][*:0]const u8{ "TMPDIR", "TMP", "TEMP" };
    for (env_names) |name| {
        const value = std.c.getenv(name) orelse continue;
        const path = std.mem.span(value);
        if (path.len == 0) continue;
        try std.testing.expectEqualStrings(path, cache_dir);
        return;
    }
    try std.testing.expectEqualStrings("/tmp", cache_dir);
}

test "recognizes strings that look like IP addresses" {
    try std.testing.expect(!util.isLikelyIPAddress(""));
    try std.testing.expect(util.isLikelyIPAddress("127.0.0.1"));
    try std.testing.expect(util.isLikelyIPAddress("999.999.999.999"));
    try std.testing.expect(util.isLikelyIPAddress("2001:db8::1"));
    try std.testing.expect(util.isLikelyIPAddress("::ffff:192.0.2.1"));
    try std.testing.expect(!util.isLikelyIPAddress("2001:db8::g"));
    try std.testing.expect(!util.isLikelyIPAddress("10.0.0.1/24"));
    try std.testing.expect(!util.isLikelyIPAddress("vpn.example.com"));
}

test "compares optional strings" {
    try std.testing.expect(util.optionalStringsEqual(null, null));
    try std.testing.expect(!util.optionalStringsEqual("alpha", null));
    try std.testing.expect(!util.optionalStringsEqual(null, "alpha"));
    try std.testing.expect(util.optionalStringsEqual("alpha", "alpha"));
    try std.testing.expect(!util.optionalStringsEqual("alpha", "beta"));
}

test "runtime platform version has major and minor components" {
    const version = try util.platformVersionAlloc(std.testing.allocator);
    defer std.testing.allocator.free(version);
    const separator = std.mem.indexOfScalar(u8, version, '.') orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(separator > 0);
    try std.testing.expect(separator + 1 < version.len);
}

test "appends owned string copies" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList([]u8) = .empty;
    defer util.deinitListOfStrings(allocator, &list);

    const original = try allocator.dupe(u8, "alpha");
    defer allocator.free(original);

    try util.appendOwned(allocator, &list, original);
    original[0] = 'A';

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("alpha", list.items[0]);
}

test "replaces owned optional strings" {
    const allocator = std.testing.allocator;
    var field: ?[]const u8 = try allocator.dupe(u8, "old");
    defer if (field) |value| allocator.free(value);

    util.replaceOwned(allocator, &field, try allocator.dupe(u8, "new"));

    try std.testing.expectEqualStrings("new", field.?);
}

test "clones string slices without aliasing" {
    const allocator = std.testing.allocator;
    const first = try allocator.dupe(u8, "one");
    defer allocator.free(first);
    const second = try allocator.dupe(u8, "two");
    defer allocator.free(second);
    const originals = [_][]u8{ first, second };

    const cloned = try util.cloneSliceOfStrings(allocator, &originals);
    defer util.freeSliceOfStrings(allocator, cloned);

    first[0] = 'O';
    cloned[1][0] = 'T';

    try std.testing.expectEqualStrings("one", cloned[0]);
    try std.testing.expectEqualStrings("Two", cloned[1]);
    try std.testing.expectEqualStrings("two", second);
}

test "deinitializes lists of owned items" {
    const allocator = std.testing.allocator;
    var deinit_count: usize = 0;
    var list: std.ArrayList(OwnedItem) = .empty;

    try list.append(allocator, try OwnedItem.init(allocator, "one", &deinit_count));
    try list.append(allocator, try OwnedItem.init(allocator, "two", &deinit_count));

    util.deinitList(OwnedItem, allocator, &list);

    try std.testing.expectEqual(@as(usize, 2), deinit_count);
}

test "clears lists of owned items while retaining capacity" {
    const allocator = std.testing.allocator;
    var deinit_count: usize = 0;
    var list: std.ArrayList(ClearItem) = .empty;
    defer list.deinit(allocator);

    try list.append(allocator, .{ .deinit_count = &deinit_count });
    try list.append(allocator, .{ .deinit_count = &deinit_count });
    const capacity = list.capacity;

    util.clearList(ClearItem, &list);

    try std.testing.expectEqual(@as(usize, 2), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(capacity, list.capacity);
}

test "clears maps of owned items while retaining capacity" {
    const allocator = std.testing.allocator;
    var deinit_count: usize = 0;
    var map = std.AutoHashMap(u32, ClearItem).init(allocator);
    defer map.deinit();

    try map.put(1, .{ .deinit_count = &deinit_count });
    try map.put(2, .{ .deinit_count = &deinit_count });
    const capacity = map.capacity();

    util.clearMap(ClearItem, &map);

    try std.testing.expectEqual(@as(usize, 2), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), map.count());
    try std.testing.expectEqual(capacity, map.capacity());
}

test "deinitializes slices of owned items" {
    const allocator = std.testing.allocator;
    var deinit_count: usize = 0;
    const items = try allocator.alloc(OwnedItem, 2);

    items[0] = try OwnedItem.init(allocator, "one", &deinit_count);
    items[1] = try OwnedItem.init(allocator, "two", &deinit_count);

    util.freeSlice(OwnedItem, allocator, items);

    try std.testing.expectEqual(@as(usize, 2), deinit_count);
}

const OwnedItem = struct {
    value: []u8,
    deinit_count: *usize,

    fn init(
        allocator: std.mem.Allocator,
        value: []const u8,
        deinit_count: *usize,
    ) error{OutOfMemory}!OwnedItem {
        return .{
            .value = try allocator.dupe(u8, value),
            .deinit_count = deinit_count,
        };
    }

    pub fn deinit(self: *OwnedItem, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.deinit_count.* += 1;
    }
};

const ClearItem = struct {
    deinit_count: *usize,

    pub fn deinit(self: *ClearItem) void {
        self.deinit_count.* += 1;
    }
};
