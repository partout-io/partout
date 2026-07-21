// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core = @import("../../core/exports.zig");
const errors = @import("errors.zig");
const PRNG = @import("prng.zig").PRNG;

const api = core.api;

pub const PIAHardReset = struct {
    pub const obfuscation_key_length: usize = 3;
    pub const magic = "53eo0rk92gxic98p1asgl5auh59r1vp4lmry1e3chzi100qntd";

    ca_md5_digest: []const u8,
    cipher: api.OpenVPNCipher,
    digest: api.OpenVPNDigest,

    pub fn init(
        ca_md5_digest: []const u8,
        cipher: api.OpenVPNCipher,
        digest: api.OpenVPNDigest,
    ) PIAHardReset {
        return .{
            .ca_md5_digest = ca_md5_digest,
            .cipher = cipher,
            .digest = digest,
        };
    }

    /// Returns the PIA-specific encoded hard-reset payload. Caller owns it.
    pub fn encodedData(
        self: PIAHardReset,
        allocator: std.mem.Allocator,
        prng: PRNG,
    ) (std.mem.Allocator.Error || errors.PIAHardResetError)![]u8 {
        if (!isASCII(self.ca_md5_digest)) return error.Assertion;

        const cipher_name = try lowerAlloc(allocator, self.cipher.raw());
        defer allocator.free(cipher_name);
        const digest_name = try lowerAlloc(allocator, self.digest.raw());
        defer allocator.free(digest_name);
        const plain = try std.fmt.allocPrint(
            allocator,
            "{s}crypto\t{s}|{s}\tca\t{s}",
            .{ magic, cipher_name, digest_name, self.ca_md5_digest },
        );
        defer allocator.free(plain);

        const result = try allocator.alloc(u8, obfuscation_key_length + plain.len);
        errdefer allocator.free(result);
        try prng.fill(result[0..obfuscation_key_length]);
        for (plain, 0..) |byte, index| {
            result[obfuscation_key_length + index] =
                byte ^ result[index % obfuscation_key_length];
        }
        return result;
    }

    fn lowerAlloc(
        allocator: std.mem.Allocator,
        value: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        const result = try allocator.alloc(u8, value.len);
        for (value, result) |source, *destination|
            destination.* = std.ascii.toLower(source);
        return result;
    }

    fn isASCII(value: []const u8) bool {
        for (value) |byte| if (!std.ascii.isAscii(byte)) return false;
        return true;
    }
};

test "PIA payload prepends the repeating XOR key" {
    const Fixed = struct {
        fn fill(_: ?*anyopaque, destination: []u8) bool {
            for (destination, 0..) |*byte, index| byte.* = @intCast(index + 1);
            return true;
        }
    };
    const value = PIAHardReset.init("012345", .aes128cbc, .sha1);
    const encoded = try value.encodedData(
        std.testing.allocator,
        .{ .fill_fn = Fixed.fill },
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, encoded[0..3]);
    try std.testing.expectEqual(@as(u8, PIAHardReset.magic[0] ^ 1), encoded[3]);
}
