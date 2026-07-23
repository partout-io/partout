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
