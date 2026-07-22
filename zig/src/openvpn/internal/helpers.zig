// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const crypto_mod = @import("crypto.zig");
const errors_mod = @import("errors.zig");
const time_c = @cImport(@cInclude("time.h"));

const api = core_mod.api;

const CryptoKeyPair = crypto_mod.CryptoKeyPair;
const CryptoKeys = crypto_mod.CryptoKeys;
const PRNG = crypto_mod.PRNG;
const StaticKeyError = errors_mod.StaticKeyError;
const ZeroingData = crypto_mod.ZeroingData;
const static_key_content_length = 256;
const static_key_length = 64;

pub fn authKeys(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) StaticKeyError!CryptoKeys {
    const bytes = try decode(allocator, key);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    const send_index: usize = switch (key.dir orelse .server) {
        .server => 1,
        .client => 3,
    };
    const receive_index: usize = switch (key.dir orelse .client) {
        .server => 3,
        .client => 1,
    };
    var send = try ZeroingData.initCopy(allocator, quadrant(bytes, send_index));
    errdefer send.deinit(allocator);
    const receive = try ZeroingData.initCopy(allocator, quadrant(bytes, receive_index));
    return CryptoKeys.init(null, CryptoKeyPair.init(send, receive));
}

pub fn BidirectionalState(comptime T: type) type {
    return struct {
        reset_value: T,
        inbound: T,
        outbound: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{
                .reset_value = value,
                .inbound = value,
                .outbound = value,
            };
        }

        pub fn reset(self: *Self) void {
            self.inbound = self.reset_value;
            self.outbound = self.reset_value;
        }
    };
}

pub fn cryptKeys(
    allocator: std.mem.Allocator,
    key: api.OpenVPNStaticKey,
) StaticKeyError!CryptoKeys {
    const direction = key.dir orelse return error.MissingStaticKeyDirection;
    const bytes = try decode(allocator, key);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    const cipher_send_index: usize = if (direction == .server) 0 else 2;
    const cipher_receive_index: usize = if (direction == .server) 2 else 0;
    const hmac_send_index: usize = if (direction == .server) 1 else 3;
    const hmac_receive_index: usize = if (direction == .server) 3 else 1;

    var cipher_send = try ZeroingData.initCopy(allocator, quadrant(bytes, cipher_send_index));
    errdefer cipher_send.deinit(allocator);
    var cipher_receive = try ZeroingData.initCopy(allocator, quadrant(bytes, cipher_receive_index));
    errdefer cipher_receive.deinit(allocator);
    var hmac_send = try ZeroingData.initCopy(allocator, quadrant(bytes, hmac_send_index));
    errdefer hmac_send.deinit(allocator);
    const hmac_receive = try ZeroingData.initCopy(allocator, quadrant(bytes, hmac_receive_index));
    return CryptoKeys.init(
        CryptoKeyPair.init(cipher_send, cipher_receive),
        CryptoKeyPair.init(hmac_send, hmac_receive),
    );
}

pub fn forAuthentication(
    allocator: std.mem.Allocator,
    credentials: api.OpenVPNCredentials,
) (std.mem.Allocator.Error || errors_mod.CredentialsError)!api.OpenVPNCredentials {
    const username = try allocator.dupe(u8, credentials.username);
    errdefer allocator.free(username);

    const password = switch (credentials.otp_method) {
        .none => try allocator.dupe(u8, credentials.password),
        .append => blk: {
            const otp = credentials.otp orelse return error.OTPRequired;
            break :blk try std.mem.concat(allocator, u8, &.{ credentials.password, otp });
        },
        .encode => blk: {
            const otp = credentials.otp orelse return error.OTPRequired;
            const encoded_password = try base64Alloc(allocator, credentials.password);
            defer allocator.free(encoded_password);
            const encoded_otp = try base64Alloc(allocator, otp);
            defer allocator.free(encoded_otp);
            break :blk try std.fmt.allocPrint(
                allocator,
                "SCRV1:{s}:{s}",
                .{ encoded_password, encoded_otp },
            );
        },
    };

    return .{
        .username = username,
        .password = password,
        .otp_method = .none,
        .otp = null,
    };
}

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
    ) (std.mem.Allocator.Error || errors_mod.PIAHardResetError)![]u8 {
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

pub fn unixSeconds() u32 {
    const raw = time_c.time(null);
    if (raw <= 0) return 0;
    return @truncate(@as(u64, @intCast(raw)));
}

fn base64Alloc(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    _ = std.base64.standard.Encoder.encode(encoded, value);
    return encoded;
}

fn decode(allocator: std.mem.Allocator, key: api.OpenVPNStaticKey) StaticKeyError![]u8 {
    const bytes = try key.data.bytesAlloc(allocator);
    errdefer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    if (bytes.len != static_key_content_length) return error.InvalidStaticKey;
    return bytes;
}

fn quadrant(bytes: []const u8, index: usize) []const u8 {
    return bytes[index * static_key_length .. (index + 1) * static_key_length];
}
