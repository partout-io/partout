// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const crypto_mod = @import("crypto.zig");

const api = core_mod.api;
const CryptoBackend = crypto_mod.CryptoBackend;
const PRNG = crypto_mod.PRNG;

pub const ConnectionOptions = struct {
    backend: CryptoBackend = .native,
    max_packets: usize = 100,
    write_timeout_ms: u64 = 5_000,
    min_data_count_interval_ms: u64 = 3_000,
    negotiation_timeout_ms: u64 = 30_000,
    hard_reset_timeout_ms: u64 = 10_000,
    tick_interval_ms: u64 = 200,
    retransmission_interval_ms: u64 = 100,
    push_request_interval_ms: u64 = 2_000,
    ping_timeout_check_interval_ms: u64 = 10_000,
    ping_timeout_ms: u64 = 120_000,
    soft_negotiation_timeout_ms: u64 = 120_000,
};

pub fn cipherKeySize(cipher: api.OpenVPNCipher) u16 {
    return switch (cipher) {
        .aes128cbc, .aes128gcm => 128,
        .aes192cbc, .aes192gcm => 192,
        .aes256cbc, .aes256gcm => 256,
    };
}

pub fn cipherEmbedsDigest(cipher: api.OpenVPNCipher) bool {
    return switch (cipher) {
        .aes128gcm, .aes192gcm, .aes256gcm => true,
        else => false,
    };
}

pub fn fallbackCipher(configuration: api.OpenVPNConfiguration) api.OpenVPNCipher {
    if (configuration.cipher) |cipher| return cipher;
    if (configuration.data_ciphers) |ciphers| {
        if (ciphers.len > 0) return ciphers[0];
    }
    return .aes128cbc;
}

pub fn fallbackDigest(configuration: api.OpenVPNConfiguration) api.OpenVPNDigest {
    return configuration.digest orelse .sha1;
}

pub fn fallbackCompressionFraming(
    configuration: api.OpenVPNConfiguration,
) api.OpenVPNCompressionFraming {
    return configuration.compression_framing orelse .disabled;
}

pub fn fallbackCompressionAlgorithm(
    configuration: api.OpenVPNConfiguration,
) api.OpenVPNCompressionAlgorithm {
    return configuration.compression_algorithm orelse .disabled;
}

pub fn containsCipher(ciphers: []const api.OpenVPNCipher, wanted: api.OpenVPNCipher) bool {
    return std.mem.indexOfScalar(api.OpenVPNCipher, ciphers, wanted) != null;
}

/// Returns an owned negotiation list. The configured fallback is appended if
/// it was not explicitly advertised, matching the Swift extension.
pub fn negotiableDataCiphers(
    allocator: std.mem.Allocator,
    configuration: api.OpenVPNConfiguration,
) !?[]api.OpenVPNCipher {
    const advertised = configuration.data_ciphers orelse return null;
    if (advertised.len == 0) return null;
    const fallback = configuration.cipher;
    const append_fallback = fallback != null and !containsCipher(advertised, fallback.?);
    const result = try allocator.alloc(api.OpenVPNCipher, advertised.len + @intFromBool(append_fallback));
    @memcpy(result[0..advertised.len], advertised);
    if (append_fallback) result[advertised.len] = fallback.?;
    return result;
}

pub fn negotiatedDataChannelCipher(
    configuration: api.OpenVPNConfiguration,
    pushed: api.OpenVPNConfiguration,
    server_cipher: ?api.OpenVPNCipher,
) api.OpenVPNCipher {
    if (pushed.cipher) |cipher| return cipher;
    if (server_cipher) |cipher| {
        if (configuration.data_ciphers) |advertised| {
            if (containsCipher(advertised, cipher) or configuration.cipher == cipher) return cipher;
        }
    }
    return fallbackCipher(configuration);
}

/// Builds the legacy OCC/auth-options string sent during key-method-2 auth.
pub fn localOptionsStringAlloc(
    allocator: std.mem.Allocator,
    configuration: api.OpenVPNConfiguration,
    with_local_options: bool,
) ![]u8 {
    if (!with_local_options) return allocator.dupe(u8, "V0 UNDEF");

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.writeAll("V4,dev-type tun") catch return error.OutOfMemory;
    if (configuration.tls_wrap) |wrap| {
        if (wrap.key.dir) |direction| {
            writer.print(",keydir {}", .{direction.raw()}) catch return error.OutOfMemory;
        }
    }
    if (configuration.cipher) |cipher| {
        writer.print(",cipher {s},keysize {}", .{
            cipher.raw(),
            cipherKeySize(cipher),
        }) catch return error.OutOfMemory;
    }
    writer.print(",auth {s}", .{fallbackDigest(configuration).raw()}) catch return error.OutOfMemory;
    if (configuration.tls_wrap) |wrap| {
        writer.print(",tls-{s}", .{wrap.strategy.raw()}) catch return error.OutOfMemory;
    }
    writer.writeAll(",key-method 2,tls-client") catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

pub fn hasPullMask(configuration: api.OpenVPNConfiguration, mask: api.OpenVPNPullMask) bool {
    const masks = configuration.no_pull_mask orelse return false;
    return std.mem.indexOfScalar(api.OpenVPNPullMask, masks, mask) != null;
}

/// Returns an owned endpoint with a random hexadecimal hostname prefix, or an
/// owned clone of an IP endpoint.
pub fn endpointWithRandomPrefix(
    allocator: std.mem.Allocator,
    endpoint: api.ExtendedEndpoint,
    length: usize,
    prng: PRNG,
) !api.ExtendedEndpoint {
    const address = api.Address.parseRaw(endpoint.address) orelse {
        return .{
            .address = try allocator.dupe(u8, endpoint.address),
            .proto = endpoint.proto,
            .owned = true,
        };
    };
    if (address.family != .hostname) {
        return .{
            .address = try allocator.dupe(u8, endpoint.address),
            .proto = endpoint.proto,
            .owned = true,
        };
    }

    const prefix = try prng.data(allocator, length);
    defer allocator.free(prefix);
    const encoded = try allocator.alloc(u8, prefix.len * 2);
    defer allocator.free(encoded);
    const alphabet = "0123456789abcdef";
    for (prefix, 0..) |byte, index| {
        encoded[index * 2] = alphabet[byte >> 4];
        encoded[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return .{
        .address = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded, endpoint.address }),
        .proto = endpoint.proto,
        .owned = true,
    };
}

/// Returns an owned copy of the configured remotes after applying endpoint
/// randomization and random hostname prefixes.
pub fn processedRemotes(
    allocator: std.mem.Allocator,
    configuration: api.OpenVPNConfiguration,
    prng: PRNG,
) !?[]api.ExtendedEndpoint {
    const source = configuration.remotes orelse return null;
    const shuffled = try allocator.dupe(api.ExtendedEndpoint, source);
    defer allocator.free(shuffled);
    if ((configuration.randomize_endpoint orelse false) and shuffled.len > 1) {
        var seed_bytes: [8]u8 = undefined;
        try prng.fill(&seed_bytes);
        var engine = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed_bytes, .little));
        engine.random().shuffle(api.ExtendedEndpoint, shuffled);
    }

    const result = try allocator.alloc(api.ExtendedEndpoint, shuffled.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*endpoint| endpoint.deinit(allocator);
        allocator.free(result);
    }
    for (shuffled, 0..) |endpoint, index| {
        result[index] = if (configuration.randomize_hostnames orelse false)
            try endpointWithRandomPrefix(allocator, endpoint, 6, prng)
        else
            .{
                .address = try allocator.dupe(u8, endpoint.address),
                .proto = endpoint.proto,
                .owned = true,
            };
        initialized += 1;
    }
    return result;
}
