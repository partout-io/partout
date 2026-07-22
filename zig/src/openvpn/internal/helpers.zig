// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const time_c = @cImport(@cInclude("time.h"));

const api = core_mod.api;

pub fn BidirectionalState(comptime T: type) type {
    return struct {
        reset_value: T,
        inbound: T,
        outbound: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{
                .reset_value = value,
                .inbound = value,
                .outbound = value,
            };
        }

        pub fn reset(self: *Self) void {
            self.inbound = self.reset_value;
            self.outbound = self.reset_value;
        }
    };
}

pub const c = @cImport({
    @cInclude("openvpn/openvpn.h");
});

pub fn forAuthentication(
    allocator: std.mem.Allocator,
    credentials: api.OpenVPNCredentials,
) !api.OpenVPNCredentials {
    const username = try allocator.dupe(u8, credentials.username);
    errdefer allocator.free(username);

    const password = switch (credentials.otp_method) {
        .none => try allocator.dupe(u8, credentials.password),
        .append => blk: {
            const otp = credentials.otp orelse return error.OTPRequired;
            break :blk try std.mem.concat(allocator, u8, &.{ credentials.password, otp });
        },
        .encode => blk: {
            const otp = credentials.otp orelse return error.OTPRequired;
            const encoded_password = try base64Alloc(allocator, credentials.password);
            defer allocator.free(encoded_password);
            const encoded_otp = try base64Alloc(allocator, otp);
            defer allocator.free(encoded_otp);
            break :blk try std.fmt.allocPrint(
                allocator,
                "SCRV1:{s}:{s}",
                .{ encoded_password, encoded_otp },
            );
        },
    };

    return .{
        .username = username,
        .password = password,
        .otp_method = .none,
        .otp = null,
    };
}

pub fn unixSeconds() u32 {
    const raw = time_c.time(null);
    if (raw <= 0) return 0;
    return @truncate(@as(u64, @intCast(raw)));
}

fn base64Alloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    _ = std.base64.standard.Encoder.encode(encoded, value);
    return encoded;
}
