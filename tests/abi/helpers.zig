// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("source").core;
const helpers = @import("source").abi_helpers;

const api = core.api;
const c = helpers.c;
const CompletionCode = c.partout_completion_code;
const InitArgs = c.partout_init_args;

test "ABI structs stay C-sized" {
    try std.testing.expect(@offsetOf(InitArgs, "logs_private_data") == 0);
    try std.testing.expect(@offsetOf(InitArgs, "logger") == @sizeOf(?*anyopaque));
    try std.testing.expect(@sizeOf(CompletionCode) == @sizeOf(c_int));
}

test "ABI import error payload includes parse error info" {
    const allocator = std.testing.allocator;
    var info: api.ParseErrorInfo = .{
        .name = "PrivateKey",
        .details = "PrivateKey = nope",
    };
    const context = core.ImportContext.init(&info, null, null);

    const c_payload = helpers.importErrorPayloadAllocZ(
        allocator,
        error.Parsing,
        context,
    ) orelse return error.TestUnexpectedResult;
    const payload_json = std.mem.span(c_payload);
    defer allocator.free(payload_json);

    var payload = try api.ABIErrorPayload.parse(allocator, payload_json);
    defer payload.deinit(allocator);
    try std.testing.expectEqual(api.PartoutErrorCode.parsing, payload.code);

    var parsed_info = try api.ParseErrorInfo.parse(allocator, payload.user_info.?.bytes);
    defer parsed_info.deinit(allocator);
    try std.testing.expectEqualStrings("PrivateKey", parsed_info.name);
    try std.testing.expectEqualStrings("PrivateKey = nope", parsed_info.details);
}
