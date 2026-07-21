// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const c = @import("c.zig").api;

pub const ControlChannel = struct {
    pub const max_payload_bytes_per_packet: usize = 1000;
    pub const early_negotiation_flags_type: u16 = 0x0001;
    pub const early_negotiation_resend_wrapped_key: u16 = 0x0001;
    pub const tls_prefix = [_]u8{ 0, 0, 0, 0, 2 };
    pub const number_of_keys: u8 = 8;
    pub const ctr_tag_length: usize = 32;
    pub const ctr_payload_length: usize =
        c.OpenVPNPacketOpcodeLength +
        c.OpenVPNPacketSessionIdLength +
        c.OpenVPNPacketReplayIdLength +
        c.OpenVPNPacketReplayTimestampLength;

    pub fn nextKey(current_key: u8) u8 {
        return @max(1, (current_key +% 1) % number_of_keys);
    }

    /// Builds the peer-info payload. `extra_lines` must contain complete
    /// `KEY=VALUE` lines; the result always ends in one newline.
    pub fn peerInfoAlloc(
        allocator: std.mem.Allocator,
        ui_version: []const u8,
        ssl_version: ?[]const u8,
        platform: ?[]const u8,
        platform_version: ?[]const u8,
        extra_lines: []const []const u8,
    ) std.mem.Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        writer.print("IV_VER=2.4\nIV_UI_VER={s}\nIV_PROTO=2\nIV_NCP=2\nIV_LZO_STUB=1\nIV_LZO=0\n", .{ui_version}) catch return error.OutOfMemory;
        if (ssl_version) |value| writer.print("IV_SSL={s}\n", .{value}) catch return error.OutOfMemory;
        if (platform) |value| writer.print("IV_PLAT={s}\n", .{value}) catch return error.OutOfMemory;
        if (platform_version) |value| writer.print("IV_PLAT_VER={s}\n", .{value}) catch return error.OutOfMemory;
        for (extra_lines) |line| writer.print("{s}\n", .{line}) catch return error.OutOfMemory;
        return output.toOwnedSlice() catch error.OutOfMemory;
    }
};

test "control keys rotate over the three-bit key space without returning zero" {
    try std.testing.expectEqual(@as(u8, 1), ControlChannel.nextKey(0));
    try std.testing.expectEqual(@as(u8, 7), ControlChannel.nextKey(6));
    try std.testing.expectEqual(@as(u8, 1), ControlChannel.nextKey(7));
}

test "peer info has Swift's single trailing newline" {
    const info = try ControlChannel.peerInfoAlloc(std.testing.allocator, "test", "TLSv1.3", "linux", "6.1", &.{"IV_CIPHERS=AES-256-GCM"});
    defer std.testing.allocator.free(info);
    try std.testing.expect(std.mem.endsWith(u8, info, "IV_CIPHERS=AES-256-GCM\n"));
    try std.testing.expect(!std.mem.endsWith(u8, info, "\n\n"));
}
