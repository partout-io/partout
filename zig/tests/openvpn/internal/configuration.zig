// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const configuration = source.openvpn_internal.configuration;

test "fallbacks mirror Swift configuration defaults" {
    const options = api.OpenVPNConfiguration{};
    try std.testing.expectEqual(api.OpenVPNCipher.aes128cbc, configuration.fallbackCipher(options));
    try std.testing.expectEqual(api.OpenVPNDigest.sha1, configuration.fallbackDigest(options));
    try std.testing.expectEqual(api.OpenVPNCompressionFraming.disabled, configuration.fallbackCompressionFraming(options));
    try std.testing.expectEqual(api.OpenVPNCompressionAlgorithm.disabled, configuration.fallbackCompressionAlgorithm(options));
}

test "local options include explicit legacy cipher" {
    const allocator = std.testing.allocator;
    const options = try configuration.localOptionsStringAlloc(allocator, .{ .cipher = .aes256gcm }, true);
    defer allocator.free(options);
    try std.testing.expectEqualStrings(
        "V4,dev-type tun,cipher AES-256-GCM,keysize 256,auth SHA1,key-method 2,tls-client",
        options,
    );
}
