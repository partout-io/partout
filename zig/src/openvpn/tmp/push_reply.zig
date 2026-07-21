// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("../../core/exports.zig").api;
const Parser = @import("../parser.zig").Parser;

pub const PushReply = struct {
    original: []u8,
    options: api.OpenVPNConfiguration,

    pub const prefix = "PUSH_REPLY,";

    pub fn parse(
        allocator: std.mem.Allocator,
        message: []const u8,
    ) anyerror!?PushReply {
        if (!std.mem.startsWith(u8, message, prefix)) return null;
        if (std.mem.indexOf(u8, message, "push-continuation 2") != null)
            return error.ContinuationPushReply;

        const raw_options = message[prefix.len..];
        const profile = try allocator.dupe(u8, raw_options);
        defer allocator.free(profile);
        for (profile) |*byte| {
            if (byte.* == ',') byte.* = '\n';
        }

        var options = try Parser.parse(allocator, profile);
        errdefer options.deinit(allocator);
        const original = try allocator.dupe(u8, message);
        return .{
            .original = original,
            .options = options,
        };
    }

    pub fn clone(self: PushReply, allocator: std.mem.Allocator) anyerror!PushReply {
        const original = try allocator.dupe(u8, self.original);
        errdefer allocator.free(original);
        return .{
            .original = original,
            .options = try self.options.clone(allocator),
        };
    }

    pub fn deinit(self: *PushReply, allocator: std.mem.Allocator) void {
        self.options.deinit(allocator);
        allocator.free(self.original);
        self.* = undefined;
    }

    /// Returns a diagnostic copy with the auth-token value removed.
    pub fn redactedAlloc(self: PushReply, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var fields = std.mem.splitScalar(u8, self.original, ',');
        var first = true;
        while (fields.next()) |field| {
            if (!first) output.writer.writeByte(',') catch return error.OutOfMemory;
            first = false;
            const trimmed = std.mem.trimStart(u8, field, " \t");
            if (std.ascii.startsWithIgnoreCase(trimmed, "auth-token")) {
                output.writer.writeAll("auth-token") catch return error.OutOfMemory;
            } else {
                output.writer.writeAll(field) catch return error.OutOfMemory;
            }
        }
        return output.toOwnedSlice() catch error.OutOfMemory;
    }
};

test "PUSH_REPLY parses through the standard OpenVPN parser" {
    var reply = (try PushReply.parse(
        std.testing.allocator,
        "PUSH_REPLY,ping 10,ping-restart 60,cipher AES-256-GCM,auth SHA256,peer-id 7",
    )).?;
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?f64, 10), reply.options.keep_alive_interval);
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, reply.options.cipher.?);
    try std.testing.expectEqual(@as(?u32, 7), reply.options.peer_id);
}

test "PUSH_REPLY clone owns independent storage" {
    var reply = (try PushReply.parse(std.testing.allocator, "PUSH_REPLY,ping 10")).?;
    defer reply.deinit(std.testing.allocator);
    var copy = try reply.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(reply.original, copy.original);
    try std.testing.expect(reply.original.ptr != copy.original.ptr);
}

test "PUSH_REPLY signals a continuation fragment" {
    try std.testing.expectError(
        error.ContinuationPushReply,
        PushReply.parse(
            std.testing.allocator,
            "PUSH_REPLY,route 10.0.0.0 255.0.0.0,push-continuation 2",
        ),
    );
}

test "PUSH_REPLY diagnostics redact auth tokens" {
    var reply = (try PushReply.parse(std.testing.allocator, "PUSH_REPLY,ping 10,auth-token secret")).?;
    defer reply.deinit(std.testing.allocator);
    const redacted = try reply.redactedAlloc(std.testing.allocator);
    defer std.testing.allocator.free(redacted);
    try std.testing.expectEqualStrings("PUSH_REPLY,ping 10,auth-token", redacted);
}
