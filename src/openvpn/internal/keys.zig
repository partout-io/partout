// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const crypto_mod = @import("crypto.zig");

const api = core_mod.api;
const ZeroingData = crypto_mod.ZeroingData;

pub const StaticKey = struct {
    pub const ParseError = std.mem.Allocator.Error || error{InvalidStaticKey};

    const content_length = 256;
    const key_count = 4;
    const key_length = content_length / key_count;
    const file_head = "-----BEGIN OpenVPN Static key V1-----";
    const file_foot = "-----END OpenVPN Static key V1-----";
    const crypt_v2_file_head = "-----BEGIN OpenVPN tls-crypt-v2 client key-----";
    const crypt_v2_file_foot = "-----END OpenVPN tls-crypt-v2 client key-----";

    data: ZeroingData,
    direction: ?api.OpenVPNStaticKeyDirection,

    pub fn init(
        allocator: std.mem.Allocator,
        key: api.OpenVPNStaticKey,
    ) !StaticKey {
        const bytes = try key.data.bytesAlloc(allocator);
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        return initBytes(bytes, key.dir);
    }

    pub fn initFile(
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        direction: ?api.OpenVPNStaticKeyDirection,
    ) ParseError!StaticKey {
        var hex: std.ArrayList(u8) = .empty;
        defer {
            @memset(hex.items, 0);
            hex.deinit(allocator);
        }

        var in_key = false;
        for (lines) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (std.ascii.eqlIgnoreCase(line, file_head)) {
                in_key = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, file_foot)) break;
            if (!in_key) continue;
            if (!core_mod.util.containsOnly(line, "0123456789abcdefABCDEF"))
                return error.InvalidStaticKey;
            try hex.appendSlice(allocator, line);
        }
        if (hex.items.len != content_length * 2) return error.InvalidStaticKey;

        var bytes: [content_length]u8 = undefined;
        defer @memset(&bytes, 0);
        _ = std.fmt.hexToBytes(&bytes, hex.items) catch return error.InvalidStaticKey;
        return initBytes(&bytes, direction);
    }

    pub fn parseFileAlloc(
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        direction: ?api.OpenVPNStaticKeyDirection,
    ) ParseError!api.OpenVPNStaticKey {
        var key = try initFile(allocator, lines, direction);
        defer key.deinit();
        return key.apiKeyAlloc(allocator);
    }

    pub fn parseCryptV2FileAlloc(
        allocator: std.mem.Allocator,
        lines: []const []const u8,
    ) ParseError!api.OpenVPNTLSWrap {
        var base64: std.ArrayList(u8) = .empty;
        defer {
            @memset(base64.items, 0);
            base64.deinit(allocator);
        }
        var in_key = false;
        for (lines) |line| {
            if (line.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(line, crypt_v2_file_head)) {
                in_key = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(line, crypt_v2_file_foot)) break;
            if (in_key) try base64.appendSlice(allocator, line);
        }

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64.items) catch
            return error.InvalidStaticKey;
        const decoded = try allocator.alloc(u8, decoded_len);
        defer {
            @memset(decoded, 0);
            allocator.free(decoded);
        }
        std.base64.standard.Decoder.decode(decoded, base64.items) catch
            return error.InvalidStaticKey;
        if (decoded.len <= content_length) return error.InvalidStaticKey;

        var static_key = try initBytes(decoded[0..content_length], .client);
        defer static_key.deinit();
        var key = try static_key.apiKeyAlloc(allocator);
        errdefer key.deinit(allocator);
        const wrapped_key = try api.SecureData.initBytesAlloc(allocator, decoded[content_length..]);
        return .{
            .strategy = .cryptV2,
            .key = key,
            .wrapped_key = wrapped_key,
        };
    }

    pub fn deinit(self: *StaticKey) void {
        self.data.deinit();
    }

    pub fn cipherEncryptKey(self: StaticKey) ![]const u8 {
        const direction = self.direction orelse return error.MissingStaticKeyDirection;
        return self.keyAt(switch (direction) {
            .server => 0,
            .client => 2,
        });
    }

    pub fn cipherDecryptKey(self: StaticKey) ![]const u8 {
        const direction = self.direction orelse return error.MissingStaticKeyDirection;
        return self.keyAt(switch (direction) {
            .server => 2,
            .client => 0,
        });
    }

    pub fn hmacSendKey(self: StaticKey) []const u8 {
        return self.keyAt(if (self.direction == .client) 3 else 1);
    }

    pub fn hmacReceiveKey(self: StaticKey) []const u8 {
        return self.keyAt(if (self.direction == .server) 3 else 1);
    }

    pub fn hexStringAlloc(self: StaticKey, allocator: std.mem.Allocator) ![]u8 {
        const bytes = self.data.asSlice();
        const hex = try allocator.alloc(u8, bytes.len * 2);
        const alphabet = "0123456789abcdef";
        for (bytes, 0..) |byte, index| {
            hex[index * 2] = alphabet[byte >> 4];
            hex[index * 2 + 1] = alphabet[byte & 0x0f];
        }
        return hex;
    }

    pub fn fileContentsAlloc(self: StaticKey, allocator: std.mem.Allocator) ![]u8 {
        const hex = try self.hexStringAlloc(allocator);
        defer {
            @memset(hex, 0);
            allocator.free(hex);
        }

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        writer.print("# 2048 bit OpenVPN static key\n{s}\n", .{file_head}) catch
            return error.OutOfMemory;
        var offset: usize = 0;
        while (offset < hex.len) : (offset += 32) {
            writer.print("{s}\n", .{hex[offset..@min(offset + 32, hex.len)]}) catch
                return error.OutOfMemory;
        }
        writer.writeAll(file_foot) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    pub fn cryptV2FileContentsAlloc(
        self: StaticKey,
        allocator: std.mem.Allocator,
        wrapped_key: api.SecureData,
    ) ![]u8 {
        const wrapped = try wrapped_key.bytesAlloc(allocator);
        defer {
            @memset(wrapped, 0);
            allocator.free(wrapped);
        }
        const key_bytes = self.data.asSlice();
        const combined_len = std.math.add(usize, key_bytes.len, wrapped.len) catch
            return error.OutOfMemory;
        const combined = try allocator.alloc(u8, combined_len);
        defer {
            @memset(combined, 0);
            allocator.free(combined);
        }
        @memcpy(combined[0..key_bytes.len], key_bytes);
        @memcpy(combined[key_bytes.len..], wrapped);

        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(combined.len));
        defer {
            @memset(encoded, 0);
            allocator.free(encoded);
        }
        _ = std.base64.standard.Encoder.encode(encoded, combined);

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        writer.print("{s}\n", .{crypt_v2_file_head}) catch return error.OutOfMemory;
        var offset: usize = 0;
        while (offset < encoded.len) : (offset += 64) {
            writer.print("{s}\n", .{encoded[offset..@min(offset + 64, encoded.len)]}) catch
                return error.OutOfMemory;
        }
        writer.writeAll(crypt_v2_file_foot) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    fn initBytes(
        bytes: []const u8,
        direction: ?api.OpenVPNStaticKeyDirection,
    ) ParseError!StaticKey {
        if (bytes.len != content_length) return error.InvalidStaticKey;
        return .{
            .data = ZeroingData.initCopy(bytes),
            .direction = direction,
        };
    }

    fn apiKeyAlloc(self: StaticKey, allocator: std.mem.Allocator) !api.OpenVPNStaticKey {
        return .{
            .data = try api.SecureData.initBytesAlloc(allocator, self.data.asSlice()),
            .dir = self.direction,
        };
    }

    fn keyAt(self: StaticKey, index: usize) []const u8 {
        const bytes = self.data.asSlice();
        if (bytes.len != content_length)
            @panic("invalid OpenVPN static key length");
        return bytes[index * key_length .. (index + 1) * key_length];
    }
};
