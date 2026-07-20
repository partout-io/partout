// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const abi = @import("source").abi;
const partout = @import("source").partout;

const partout_version = partout.partout_version;
test {
    _ = abi;
}

test "version matches Swift package constant" {
    try std.testing.expectEqualStrings("io.partout 0.151.0", std.mem.span(partout_version()));
}
