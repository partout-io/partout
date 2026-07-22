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
    ) anyerror!?PushReply {
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

    pub fn clone(self: PushReply, allocator: std.mem.Allocator) anyerror!PushReply {
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
) std.mem.Allocator.Error![]u8 {
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
fn platformVersionAlloc(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
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

fn darwinVersionAlloc(allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
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

fn posixVersionAlloc(allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
    const information = std.posix.uname();
    return majorMinorAlloc(allocator, std.mem.sliceTo(&information.release, 0));
}

fn windowsVersionAlloc(allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
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
) std.mem.Allocator.Error!?[]u8 {
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
) std.mem.Allocator.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.print("IV_VER=2.4\nIV_UI_VER={s}\nIV_PROTO=2\nIV_NCP=2\nIV_LZO_STUB=1\nIV_LZO=0\n", .{ui_version}) catch return error.OutOfMemory;
    if (ssl_version) |value| writer.print("IV_SSL={s}\n", .{value}) catch return error.OutOfMemory;
    writer.print("IV_PLAT={s}\nIV_PLAT_VER={s}\n", .{ platform, platform_version }) catch return error.OutOfMemory;
    for (extra_lines) |line| writer.print("{s}\n", .{line}) catch return error.OutOfMemory;
    return output.toOwnedSlice() catch error.OutOfMemory;
}

test "PUSH_REPLY parses through the standard OpenVPN parser" {
    var reply = (try PushReply.parse(
        std.testing.allocator,
        "PUSH_REPLY,ping 10,ping-restart 60,cipher AES-256-GCM,auth SHA256,peer-id 7",
    )).?;
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?f64, 10), reply.options.keep_alive_interval);
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, reply.options.cipher.?);
    try std.testing.expectEqual(@as(?u32, 7), reply.options.peer_id);
}

test "PUSH_REPLY clone owns independent storage" {
    var reply = (try PushReply.parse(std.testing.allocator, "PUSH_REPLY,ping 10")).?;
    defer reply.deinit(std.testing.allocator);
    var copy = try reply.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(reply.original, copy.original);
    try std.testing.expect(reply.original.ptr != copy.original.ptr);
}

test "PUSH_REPLY signals a continuation fragment" {
    try std.testing.expectError(
        error.ContinuationPushReply,
        PushReply.parse(
            std.testing.allocator,
            "PUSH_REPLY,route 10.0.0.0 255.0.0.0,push-continuation 2",
        ),
    );
}

test "runtime platform version has major and minor components" {
    const version = try platformVersionAlloc(std.testing.allocator);
    defer std.testing.allocator.free(version);
    const separator = std.mem.indexOfScalar(u8, version, '.') orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(separator > 0);
    try std.testing.expect(separator + 1 < version.len);
}

test "peer info has one trailing newline" {
    const info = try formatPeerInfoAlloc(
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
