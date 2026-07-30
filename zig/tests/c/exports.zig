// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const c_exports = source.c_exports;
const c_common = c_exports.common;
const c_crypto = c_exports.crypto;

test "portable filesystem creates nested directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const nested = try std.fmt.allocPrintSentinel(
        allocator,
        ".zig-cache/tmp/{s}/first/second",
        .{tmp.sub_path},
        0,
    );
    defer allocator.free(nested);

    try std.testing.expect(c_common.pp_file_create_directory(nested.ptr));
    try std.testing.expect(c_common.pp_file_is_directory(nested.ptr));
    try std.testing.expect(c_common.pp_file_create_directory(nested.ptr));
}

test "portable clock returns Unix time" {
    try std.testing.expect(c_common.pp_time_unix_seconds() > 0);
}

test "default crypto backend follows compiled backends" {
    const expected: c_exports.CryptoBackend =
        if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_OPENSSL"))
            .openssl
        else if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_MBEDTLS"))
            .native
        else
            .mock;
    try std.testing.expectEqual(expected, c_exports.CryptoBackend.default());
}

test "crypto function table follows the selected backend" {
    const mock = try c_exports.cryptoFunctionTable(.mock);
    try std.testing.expectEqualStrings("mock", std.mem.span(mock.name));

    if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_OPENSSL")) {
        const openssl = try c_exports.cryptoFunctionTable(.openssl);
        try std.testing.expectEqualStrings("openssl", std.mem.span(openssl.name));
    } else {
        try std.testing.expectError(
            error.UnsupportedCryptoBackend,
            c_exports.cryptoFunctionTable(.openssl),
        );
    }
    if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_MBEDTLS")) {
        const mbedtls = try c_exports.cryptoFunctionTable(.mbedtls);
        try std.testing.expectEqualStrings("mbed", std.mem.span(mbedtls.name));
        const native = try c_exports.cryptoFunctionTable(.native);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.span(native.name), "native-"));
    } else {
        try std.testing.expectError(
            error.UnsupportedCryptoBackend,
            c_exports.cryptoFunctionTable(.mbedtls),
        );
        try std.testing.expectError(
            error.UnsupportedCryptoBackend,
            c_exports.cryptoFunctionTable(.native),
        );
    }
}
