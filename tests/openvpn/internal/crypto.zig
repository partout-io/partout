// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const crypto = source.openvpn_internal.crypto;

test "PRNG binds its provider at compile time" {
    const Fixed = struct {
        byte: u8,

        pub fn fill(self: @This(), destination: []u8) bool {
            @memset(destination, self.byte);
            return true;
        }
    };
    const FixedPRNG = crypto.PRNGWith(Fixed);
    const prng = FixedPRNG.init(.{ .byte = 0x5a });
    var bytes: [4]u8 = undefined;
    try prng.fill(&bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x5a, 0x5a, 0x5a, 0x5a }, &bytes);
}

test "ZeroingData delegates append and slice to pp_zd" {
    var data = crypto.ZeroingData.initCopy("abc");
    defer data.deinit();
    data.append("def");
    try std.testing.expectEqualStrings("abcdef", data.asSlice());
    data.append(data.asSlice()[1..3]);
    try std.testing.expectEqualStrings("abcdefbc", data.asSlice());

    var part = try data.sliceCopy(2, 3);
    defer part.deinit();
    try std.testing.expectEqualStrings("cde", part.asSlice());
    try std.testing.expectError(
        error.OutOfBounds,
        data.sliceCopy(std.math.maxInt(usize), 1),
    );

    data.clear();
    try std.testing.expectEqual(@as(usize, 0), data.length());
    data.append("new");
    try std.testing.expectEqualStrings("new", data.asSlice());
}
