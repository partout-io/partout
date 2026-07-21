// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

/// OpenVPN's platform identifier used in peer-info.
pub fn name() []const u8 {
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
pub fn versionAlloc(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
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

test "runtime platform version has major and minor components" {
    const version = try versionAlloc(std.testing.allocator);
    defer std.testing.allocator.free(version);
    const separator = std.mem.indexOfScalar(u8, version, '.') orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(separator > 0);
    try std.testing.expect(separator + 1 < version.len);
}
