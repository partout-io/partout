// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const errors = @import("errors.zig");

const api = core.api;

/// Produces an owned credential value ready for OpenVPN authentication.
pub fn forAuthentication(
    allocator: std.mem.Allocator,
    credentials: api.OpenVPNCredentials,
) (std.mem.Allocator.Error || errors.CredentialsError)!api.OpenVPNCredentials {
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

fn base64Alloc(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    _ = std.base64.standard.Encoder.encode(encoded, value);
    return encoded;
}

test "forAuthentication appends and encodes OTP" {
    const allocator = std.testing.allocator;

    var appended = try forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .append,
        .otp = "123",
    });
    defer appended.deinit(allocator);
    try std.testing.expectEqualStrings("pass123", appended.password);

    var encoded = try forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .encode,
        .otp = "123",
    });
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings("SCRV1:cGFzcw==:MTIz", encoded.password);
}
