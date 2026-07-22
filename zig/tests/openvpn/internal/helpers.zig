// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const helpers = source.openvpn_internal.helpers;

test "BidirectionalState resets both directions" {
    var state = helpers.BidirectionalState(u32).init(7);
    state.inbound = 1;
    state.outbound = 2;
    state.reset();
    try std.testing.expectEqual(@as(u32, 7), state.inbound);
    try std.testing.expectEqual(@as(u32, 7), state.outbound);
}

test "forAuthentication appends and encodes OTP" {
    const allocator = std.testing.allocator;

    var appended = try helpers.forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .append,
        .otp = "123",
    });
    defer appended.deinit(allocator);
    try std.testing.expectEqualStrings("pass123", appended.password);

    var encoded = try helpers.forAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .encode,
        .otp = "123",
    });
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings("SCRV1:cGFzcw==:MTIz", encoded.password);
}
