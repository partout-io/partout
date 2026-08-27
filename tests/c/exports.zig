// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const c_exports = source.c_exports;
const c_common = c_exports.common;

test "portable filesystem creates nested directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const nested = try std.fmt.allocPrintSentinel(
        allocator,
        ".zig-cache/tmp/{s}/first/second",
        .{tmp.sub_path},
        0,
    );
    defer allocator.free(nested);

    try std.testing.expect(c_common.pp_file_create_directory(nested.ptr));
    try std.testing.expect(c_common.pp_file_is_directory(nested.ptr));
    try std.testing.expect(c_common.pp_file_create_directory(nested.ptr));
}

test "portable clock returns Unix time" {
    try std.testing.expect(c_common.pp_time_unix_seconds() > 0);
}
