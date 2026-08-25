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

test "ABI import error envelope includes parse error info" {
    const allocator = std.testing.allocator;
    var info: api.ParseErrorInfo = .{
        .name = "PrivateKey",
        .line = "PrivateKey = nope",
        .arguments = &.{"nope"},
    };
    const context = core.ImportContext.init(&info, null, null);

    const c_payload = helpers.importErrorPayloadAllocZ(
        allocator,
        error.Parsing,
        context,
    ) orelse return error.TestUnexpectedResult;
    const payload_json = std.mem.span(c_payload);
    defer allocator.free(payload_json);

    var envelope = try api.ABIEnvelope.parse(allocator, payload_json);
    defer envelope.deinit(allocator);
    try std.testing.expectEqual(api.PartoutErrorCode.parsing, envelope.code.?);

    var parsed_info = try api.ParseErrorInfo.parse(allocator, envelope.payload.?.bytes);
    defer parsed_info.deinit(allocator);
    try std.testing.expectEqualStrings("PrivateKey", parsed_info.name.?);
    try std.testing.expectEqualStrings("PrivateKey = nope", parsed_info.line.?);
    try std.testing.expectEqual(@as(usize, 1), parsed_info.arguments.len);
    try std.testing.expectEqualStrings("nope", parsed_info.arguments[0]);
}

test "ABI import error envelope preserves parse error sub-code in payload" {
    const allocator = std.testing.allocator;
    var info: api.ParseErrorInfo = .{
        .sub_code = .wireGuardPeerHasNoPublicKey,
        .line = "AllowedIPs = 0.0.0.0/0",
    };
    const context = core.ImportContext.init(&info, null, null);

    const c_payload = helpers.importErrorPayloadAllocZ(
        allocator,
        error.InvalidProfile,
        context,
    ) orelse return error.TestUnexpectedResult;
    const payload_json = std.mem.span(c_payload);
    defer allocator.free(payload_json);

    var envelope = try api.ABIEnvelope.parse(allocator, payload_json);
    defer envelope.deinit(allocator);
    try std.testing.expectEqual(api.PartoutErrorCode.wireGuardPeerHasNoPublicKey, envelope.code.?);

    var parsed_info = try api.ParseErrorInfo.parse(allocator, envelope.payload.?.bytes);
    defer parsed_info.deinit(allocator);
    try std.testing.expectEqual(api.PartoutErrorCode.wireGuardPeerHasNoPublicKey, parsed_info.sub_code.?);
    try std.testing.expect(std.mem.indexOf(u8, envelope.payload.?.bytes, "\"subCode\"") != null);
}

test "ABI import errors map to stable public codes" {
    const allocator = std.testing.allocator;
    const context = core.ImportContext.init(null, null, null);
    const cases = .{
        .{ error.OutOfMemory, api.PartoutErrorCode.outOfMemory },
        .{ error.IdGeneration, api.PartoutErrorCode.unhandled },
        .{ error.InvalidJson, api.PartoutErrorCode.decoding },
        .{ error.InvalidProfile, api.PartoutErrorCode.decoding },
        .{ error.InvalidModel, api.PartoutErrorCode.encoding },
        .{ error.Stringify, api.PartoutErrorCode.encoding },
        .{ error.Parsing, api.PartoutErrorCode.parsing },
        .{ error.PassphraseRequired, api.PartoutErrorCode.passphraseRequired },
        .{ error.UnknownImportedModule, api.PartoutErrorCode.unknownImportedModule },
    };

    inline for (cases) |entry| {
        const c_payload = helpers.importErrorPayloadAllocZ(
            allocator,
            entry[0],
            context,
        ) orelse return error.TestUnexpectedResult;
        const payload_json = std.mem.span(c_payload);
        defer allocator.free(payload_json);

        var envelope = try api.ABIEnvelope.parse(allocator, payload_json);
        defer envelope.deinit(allocator);
        try std.testing.expectEqual(entry[1], envelope.code.?);
        try std.testing.expect(envelope.payload == null);
    }
}
