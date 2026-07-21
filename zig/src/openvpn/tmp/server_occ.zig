// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const api = @import("../../core/exports.zig").api;

pub const ServerOCC = struct {
    cipher: ?api.OpenVPNCipher = null,
    digest: ?api.OpenVPNDigest = null,

    pub fn parse(string: []const u8) ServerOCC {
        var result: ServerOCC = .{};
        var lines = std.mem.splitScalar(u8, string, ',');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            var components = std.mem.tokenizeAny(u8, line, " \t\r\n");
            const option = components.next() orelse continue;
            const value = components.next() orelse continue;

            if (std.ascii.eqlIgnoreCase(option, "cipher")) {
                result.cipher = parseCipher(value);
            } else if (std.ascii.eqlIgnoreCase(option, "data-ciphers-fallback")) {
                if (result.cipher == null) result.cipher = parseCipher(value);
            } else if (std.ascii.eqlIgnoreCase(option, "auth")) {
                result.digest = parseDigest(value);
            }
        }
        return result;
    }

    fn parseCipher(value: []const u8) ?api.OpenVPNCipher {
        inline for (std.meta.tags(api.OpenVPNCipher)) |candidate| {
            if (std.ascii.eqlIgnoreCase(value, candidate.raw())) return candidate;
        }
        return null;
    }

    fn parseDigest(value: []const u8) ?api.OpenVPNDigest {
        inline for (std.meta.tags(api.OpenVPNDigest)) |candidate| {
            if (std.ascii.eqlIgnoreCase(value, candidate.raw())) return candidate;
        }
        return null;
    }
};

test "server OCC extracts only runtime-relevant values" {
    const occ = ServerOCC.parse("V4,dev-type tun,cipher aes-256-cbc,auth sha256,key-method 2");
    try std.testing.expectEqual(api.OpenVPNCipher.aes256cbc, occ.cipher.?);
    try std.testing.expectEqual(api.OpenVPNDigest.sha256, occ.digest.?);
}

test "explicit cipher wins over fallback alias" {
    const occ = ServerOCC.parse("cipher AES-256-GCM,data-ciphers-fallback AES-128-CBC");
    try std.testing.expectEqual(api.OpenVPNCipher.aes256gcm, occ.cipher.?);
}
