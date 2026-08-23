// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const constants_mod = @import("constants.zig");
const logging = @import("logging.zig");
const parser_mod = @import("../parser.zig");

const api = core_mod.api;
const log = core_mod.logging;

const DataConstants = constants_mod.Data;
const Parser = parser_mod.Parser;
const ParseError = std.mem.Allocator.Error || error{
    ContinuationPushReply,
    InvalidPushReply,
    UnsupportedCompression,
};

pub const PushReply = struct {
    original: []const u8,
    options: api.OpenVPNConfiguration,

    pub const prefix = "PUSH_REPLY,";
    pub const logging_formatter = logging.pushReply;

    pub fn parse(
        allocator: std.mem.Allocator,
        message: []const u8,
    ) ParseError!?PushReply {
        if (!std.mem.startsWith(u8, message, prefix)) return null;
        if (std.mem.indexOf(u8, message, "push-continuation 2") != null)
            return error.ContinuationPushReply;

        const raw_options = message[prefix.len..];
        const profile = try allocator.dupe(u8, raw_options);
        defer allocator.free(profile);
        for (profile) |*byte| {
            if (byte.* == ',') byte.* = '\n';
        }

        var options = Parser.parse(allocator, profile) catch |err| {
            log.writef(.err, "Unable to parse PUSH_REPLY: {s}", .{@errorName(err)});
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedCompression => error.UnsupportedCompression,
                else => error.InvalidPushReply,
            };
        };
        errdefer options.deinit(allocator);
        const original = try allocator.dupe(u8, message);
        return .{
            .original = original,
            .options = options,
        };
    }

    pub fn clone(self: PushReply, allocator: std.mem.Allocator) ParseError!PushReply {
        const original = try allocator.dupe(u8, self.original);
        errdefer allocator.free(original);
        return .{
            .original = original,
            .options = self.options.clone(allocator) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidPushReply,
                };
            },
        };
    }

    pub fn deinit(self: *PushReply, allocator: std.mem.Allocator) void {
        self.options.deinit(allocator);
        allocator.free(self.original);
    }
};

pub fn peerInfoAlloc(
    allocator: std.mem.Allocator,
    ui_version: []const u8,
    ssl_version: ?[]const u8,
    data_ciphers: ?[]const api.OpenVPNCipher,
) ![]u8 {
    const platform_version = try core_mod.util.platformVersionAlloc(allocator);
    defer allocator.free(platform_version);
    return formatPeerInfoAlloc(
        allocator,
        ui_version,
        ssl_version,
        core_mod.util.platformName(),
        platform_version,
        data_ciphers,
    );
}

pub const testing = struct {
    pub const formatPeerInfo = formatPeerInfoAlloc;
};

fn formatPeerInfoAlloc(
    allocator: std.mem.Allocator,
    ui_version: []const u8,
    ssl_version: ?[]const u8,
    platform: []const u8,
    platform_version: []const u8,
    data_ciphers: ?[]const api.OpenVPNCipher,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    const fields = [_]struct {
        name: []const u8,
        value: ?[]const u8,
    }{
        .{ .name = "IV_VER", .value = "2.4" },
        .{ .name = "IV_UI_VER", .value = ui_version },
        .{ .name = "IV_PROTO", .value = "2" },
        .{ .name = "IV_NCP", .value = "2" },
        .{
            .name = "IV_MTU",
            .value = std.fmt.comptimePrint("{d}", .{DataConstants.tun_max_mtu}),
        },
        .{ .name = "IV_LZO_STUB", .value = "1" },
        .{ .name = "IV_LZO", .value = "0" },
        .{ .name = "IV_SSL", .value = ssl_version },
        .{ .name = "IV_PLAT", .value = platform },
        .{ .name = "IV_PLAT_VER", .value = platform_version },
    };
    for (fields) |field| {
        const value = field.value orelse continue;
        writer.print("{s}={s}\n", .{ field.name, value }) catch
            return error.OutOfMemory;
    }
    if (data_ciphers) |ciphers| {
        writer.writeAll("IV_CIPHERS=") catch return error.OutOfMemory;
        for (ciphers, 0..) |cipher, index| {
            if (index > 0) writer.writeByte(':') catch return error.OutOfMemory;
            writer.writeAll(cipher.raw()) catch return error.OutOfMemory;
        }
        writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return output.toOwnedSlice() catch error.OutOfMemory;
}
