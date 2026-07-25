// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const source = @import("source");

const c_exports = source.c_exports;
const c_crypto = c_exports.crypto;

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
    const mock = c_exports.cryptoFunctionTable(.mock);
    try std.testing.expectEqualStrings("mock", std.mem.span(mock.name));

    if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_OPENSSL")) {
        const openssl = c_exports.cryptoFunctionTable(.openssl);
        try std.testing.expectEqualStrings("openssl", std.mem.span(openssl.name));
    }
    if (@hasDecl(c_crypto, "PARTOUT_CRYPTO_MBEDTLS")) {
        const mbedtls = c_exports.cryptoFunctionTable(.mbedtls);
        try std.testing.expectEqualStrings("mbed", std.mem.span(mbedtls.name));
        const native = c_exports.cryptoFunctionTable(.native);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.span(native.name), "native-"));
    }
}
