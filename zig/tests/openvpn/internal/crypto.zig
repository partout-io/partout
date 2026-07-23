// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const crypto = source.openvpn_internal.crypto;

test "ZeroingData delegates append and slice to pp_zd" {
    const allocator = std.testing.allocator;
    var data = try crypto.ZeroingData.initCopy(allocator, "abc");
    defer data.deinit(allocator);
    try data.append(allocator, "def");
    try std.testing.expectEqualStrings("abcdef", data.bytes);

    var part = try data.sliceCopy(allocator, 2, 3);
    defer part.deinit(allocator);
    try std.testing.expectEqualStrings("cde", part.bytes);
}
