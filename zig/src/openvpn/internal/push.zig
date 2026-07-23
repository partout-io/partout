// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const core_mod = @import("../../core/exports.zig");
const parser_mod = @import("../parser.zig");

const api = core_mod.api;

const Parser = parser_mod.Parser;

pub const PushReply = struct {
    original: []u8,
    options: api.OpenVPNConfiguration,

    pub const prefix = "PUSH_REPLY,";

    pub fn parse(
        allocator: std.mem.Allocator,
        message: []const u8,
    ) !?PushReply {
        if (!std.mem.startsWith(u8, message, prefix)) return null;
        if (std.mem.indexOf(u8, message, "push-continuation 2") != null)
            return error.ContinuationPushReply;

        const raw_options = message[prefix.len..];
        const profile = try allocator.dupe(u8, raw_options);
        defer allocator.free(profile);
        for (profile) |*byte| {
            if (byte.* == ',') byte.* = '\n';
        }

        var options = try Parser.parse(allocator, profile);
        errdefer options.deinit(allocator);
        const original = try allocator.dupe(u8, message);
        return .{
            .original = original,
            .options = options,
        };
    }

    pub fn clone(self: PushReply, allocator: std.mem.Allocator) !PushReply {
        const original = try allocator.dupe(u8, self.original);
        errdefer allocator.free(original);
        return .{
            .original = original,
            .options = try self.options.clone(allocator),
        };
    }

    pub fn deinit(self: *PushReply, allocator: std.mem.Allocator) void {
        self.options.deinit(allocator);
        allocator.free(self.original);
        self.* = undefined;
    }
};

pub fn peerInfoAlloc(
    allocator: std.mem.Allocator,
    ui_version: []const u8,
    ssl_version: ?[]const u8,
    extra_lines: []const []const u8,
) ![]u8 {
    const platform_version = try platformVersionAlloc(allocator);
    defer allocator.free(platform_version);
    return formatPeerInfoAlloc(
        allocator,
        ui_version,
        ssl_version,
        platformName(),
        platform_version,
        extra_lines,
    );
}

pub const testing = struct {
    pub const formatPeerInfo = formatPeerInfoAlloc;
    pub const platformVersion = platformVersionAlloc;
};

fn platformName() []const u8 {
    if (builtin.target.abi.isAndroid()) return "android";
    return switch (builtin.os.tag) {
        .ios, .maccatalyst => "ios",
        .tvos => "tvos",
        .macos => "mac",
        .linux => "linux",
        .windows => "windows",
        else => "unknown",
    };
}

/// Returns the runtime operating-system major/minor version used in peer-info.
/// The caller owns the returned string.
fn platformVersionAlloc(allocator: std.mem.Allocator) ![]u8 {
    const detected = if (builtin.os.tag.isDarwin())
        try darwinVersionAlloc(allocator)
    else switch (builtin.os.tag) {
        .dragonfly,
        .freebsd,
        .haiku,
        .hurd,
        .illumos,
        .linux,
        .netbsd,
        .openbsd,
        .serenity,
        => try posixVersionAlloc(allocator),
        .windows => try windowsVersionAlloc(allocator),
        else => null,
    };
    return detected orelse allocator.dupe(u8, "0.0");
}

fn darwinVersionAlloc(allocator: std.mem.Allocator) !?[]u8 {
    var buffer: [64]u8 = @splat(0);
    var length = buffer.len;
    if (std.c.sysctlbyname(
        "kern.osproductversion",
        @ptrCast(&buffer),
        &length,
        null,
        0,
    ) == 0) {
        const bounded = buffer[0..@min(length, buffer.len)];
        if (try majorMinorAlloc(allocator, std.mem.sliceTo(bounded, 0))) |version|
            return version;
    }
    return posixVersionAlloc(allocator);
}

fn posixVersionAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const information = std.posix.uname();
    return majorMinorAlloc(allocator, std.mem.sliceTo(&information.release, 0));
}

fn windowsVersionAlloc(allocator: std.mem.Allocator) !?[]u8 {
    var information: std.os.windows.RTL_OSVERSIONINFOW = std.mem.zeroes(
        std.os.windows.RTL_OSVERSIONINFOW,
    );
    information.dwOSVersionInfoSize = @sizeOf(@TypeOf(information));
    if (std.os.windows.ntdll.RtlGetVersion(&information) != .SUCCESS) return null;
    return try std.fmt.allocPrint(
        allocator,
        "{d}.{d}",
        .{ information.dwMajorVersion, information.dwMinorVersion },
    );
}

fn majorMinorAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !?[]u8 {
    var components = std.mem.splitScalar(u8, raw, '.');
    const major = numericPrefix(components.next() orelse return null);
    const minor = numericPrefix(components.next() orelse return null);
    if (major.len == 0 or minor.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ major, minor });
}

fn numericPrefix(value: []const u8) []const u8 {
    var end: usize = 0;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    return value[0..end];
}

fn formatPeerInfoAlloc(
    allocator: std.mem.Allocator,
    ui_version: []const u8,
    ssl_version: ?[]const u8,
    platform: []const u8,
    platform_version: []const u8,
    extra_lines: []const []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    const fields = [_]struct {
        name: []const u8,
        value: ?[]const u8,
    }{
        .{ .name = "IV_VER", .value = "2.4" },
        .{ .name = "IV_UI_VER", .value = ui_version },
        .{ .name = "IV_PROTO", .value = "2" },
        .{ .name = "IV_NCP", .value = "2" },
        .{ .name = "IV_LZO_STUB", .value = "1" },
        .{ .name = "IV_LZO", .value = "0" },
        .{ .name = "IV_SSL", .value = ssl_version },
        .{ .name = "IV_PLAT", .value = platform },
        .{ .name = "IV_PLAT_VER", .value = platform_version },
    };
    for (fields) |field| {
        const value = field.value orelse continue;
        writer.print("{s}={s}\n", .{ field.name, value }) catch
            return error.OutOfMemory;
    }
    for (extra_lines) |line| {
        writer.print("{s}\n", .{line}) catch return error.OutOfMemory;
    }
    return output.toOwnedSlice() catch error.OutOfMemory;
}
