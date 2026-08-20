// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const api = source.core.api;
const configuration = source.openvpn_internal.configuration;

test "fallbacks mirror Swift configuration defaults" {
    const options = api.OpenVPNConfiguration{};
    try std.testing.expectEqual(api.OpenVPNCipher.aes128cbc, configuration.fallbackCipher(&options));
    try std.testing.expectEqual(api.OpenVPNDigest.sha1, configuration.fallbackDigest(&options));
    try std.testing.expectEqual(api.OpenVPNCompressionFraming.disabled, configuration.fallbackCompressionFraming(&options));
    try std.testing.expectEqual(api.OpenVPNCompressionAlgorithm.disabled, configuration.fallbackCompressionAlgorithm(&options));
}

test "fallback cipher uses the first advertised data cipher" {
    const ciphers = [_]api.OpenVPNCipher{.aes256cbc};
    const options = api.OpenVPNConfiguration{ .data_ciphers = &ciphers };
    try std.testing.expectEqual(api.OpenVPNCipher.aes256cbc, configuration.fallbackCipher(&options));
}

test "negotiable data ciphers append an explicit legacy cipher" {
    const allocator = std.testing.allocator;
    const advertised = [_]api.OpenVPNCipher{ .aes256gcm, .aes128gcm };
    const options = api.OpenVPNConfiguration{
        .cipher = .aes128cbc,
        .data_ciphers = &advertised,
    };
    const ciphers = (try configuration.negotiableDataCiphers(allocator, &options)).?;
    defer allocator.free(ciphers);

    try std.testing.expectEqualSlices(
        api.OpenVPNCipher,
        &.{ .aes256gcm, .aes128gcm, .aes128cbc },
        ciphers,
    );
}

test "normalized explicit fallback is not duplicated in negotiation list" {
    const allocator = std.testing.allocator;
    const advertised = [_]api.OpenVPNCipher{ .aes256gcm, .aes128cbc };
    const options = api.OpenVPNConfiguration{
        .cipher = .aes128cbc,
        .data_ciphers = &advertised,
    };

    try std.testing.expectEqual(
        api.OpenVPNCipher.aes128cbc,
        configuration.fallbackCipher(&options),
    );
    const negotiable = (try configuration.negotiableDataCiphers(allocator, &options)).?;
    defer allocator.free(negotiable);
    try std.testing.expectEqualSlices(
        api.OpenVPNCipher,
        &advertised,
        negotiable,
    );
}

test "local options include explicit legacy cipher" {
    const allocator = std.testing.allocator;
    const options = try configuration.localOptionsStringAlloc(allocator, &.{ .cipher = .aes256gcm }, true);
    defer allocator.free(options);
    try std.testing.expectEqualStrings(
        "V4,dev-type tun,cipher AES-256-GCM,keysize 256,auth SHA1,key-method 2,tls-client",
        options,
    );
}

test "local options omit cipher and key size without a legacy cipher" {
    const allocator = std.testing.allocator;
    const advertised = [_]api.OpenVPNCipher{.aes256cbc};
    const options = try configuration.localOptionsStringAlloc(
        allocator,
        &.{ .data_ciphers = &advertised },
        true,
    );
    defer allocator.free(options);

    try std.testing.expect(std.mem.indexOf(u8, options, "cipher ") == null);
    try std.testing.expect(std.mem.indexOf(u8, options, "keysize ") == null);
    try std.testing.expect(std.mem.indexOf(u8, options, "auth SHA1") != null);
}

test "data channel cipher negotiation follows push, server, then fallback precedence" {
    const advertised = [_]api.OpenVPNCipher{ .aes256gcm, .aes128gcm };
    const local = api.OpenVPNConfiguration{
        .cipher = .aes128cbc,
        .data_ciphers = &advertised,
    };
    const no_push = api.OpenVPNConfiguration{};
    const pushed = api.OpenVPNConfiguration{ .cipher = .aes128gcm };

    try std.testing.expectEqual(
        api.OpenVPNCipher.aes128cbc,
        configuration.negotiatedDataChannelCipher(&local, &no_push, null),
    );
    try std.testing.expectEqual(
        api.OpenVPNCipher.aes128gcm,
        configuration.negotiatedDataChannelCipher(&local, &pushed, null),
    );
    try std.testing.expectEqual(
        api.OpenVPNCipher.aes256gcm,
        configuration.negotiatedDataChannelCipher(&local, &no_push, .aes256gcm),
    );
}

test "processed remotes randomize only hostnames" {
    const allocator = std.testing.allocator;
    const remotes = [_]api.ExtendedEndpoint{
        api.ExtendedEndpoint.init("vpn.example.com", .init(.udp, 1194)).?,
        api.ExtendedEndpoint.init("192.0.2.1", .init(.udp4, 1194)).?,
    };
    const options = api.OpenVPNConfiguration{
        .remotes = &remotes,
        .randomize_hostnames = true,
    };
    const processed = (try configuration.processedRemotes(
        allocator,
        &options,
        .system(),
    )).?;
    defer {
        for (processed) |*endpoint| endpoint.deinit(allocator);
        allocator.free(processed);
    }

    try std.testing.expect(std.mem.endsWith(u8, processed[0].address, ".vpn.example.com"));
    const prefix = processed[0].address[0 .. processed[0].address.len - ".vpn.example.com".len];
    try std.testing.expectEqual(@as(usize, 12), prefix.len);
    for (prefix) |byte| try std.testing.expect(std.ascii.isHex(byte));
    try std.testing.expectEqualStrings("192.0.2.1", processed[1].address);
}

test "credentialsForAuthentication appends and encodes OTP" {
    const allocator = std.testing.allocator;

    var appended = try configuration.credentialsForAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .append,
        .otp = "123",
    });
    defer appended.deinit(allocator);
    try std.testing.expectEqualStrings("pass123", appended.password);

    var encoded = try configuration.credentialsForAuthentication(allocator, .{
        .username = "user",
        .password = "pass",
        .otp_method = .encode,
        .otp = "123",
    });
    defer encoded.deinit(allocator);
    try std.testing.expectEqualStrings("SCRV1:cGFzcw==:MTIz", encoded.password);
}
