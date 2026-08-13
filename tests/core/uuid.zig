// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const uuid = @import("source").core_uuid;

const isV4 = uuid.isV4;
const isValid = uuid.isValid;
const newId = uuid.newId;
const parse = uuid.parse;
test "generates UUID v4 string" {
    const id = try newId();
    try std.testing.expect(isV4(id[0..]));
}

test "parses canonical UUID strings" {
    try std.testing.expect(isValid("00000000-0000-4000-8000-000000000000"));
    try std.testing.expect(!isValid("not-a-uuid"));
    const parsed = parse("00000000-0000-4000-8000-000000000000") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", parsed[0..]);
}
