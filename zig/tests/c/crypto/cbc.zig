// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const helpers = @import("helpers.zig");
const c = helpers.c;

const plain = helpers.hex("00112233ffddaa");
const plain_hmac = helpers.hex("8dd324c81ca32f52e4aa1aa35139deba799a68460e80b0e5ac8bceb043edf6e500112233ffddaa");
const encrypted_hmac = helpers.hex("fea3fe87ee68eb21c697e62d3c29f7bea2f5b457d9a7fa66291322fc9c2fe6f700000000000000000000000000000000ebe197e706c3c5dcad026f4e3af1048b");

test "CBC encryption matches the vectors" {
    for (helpers.backends()) |backend| {
        errdefer helpers.reportFailure(backend);

        if (backend.kind == .openssl) {
            try expectEncryption(backend, null, &plain_hmac);
        }
        try expectEncryption(backend, "aes-128-cbc", &encrypted_hmac);
    }
}

test "CBC authenticated data decrypts" {
    for (helpers.backends()) |backend| {
        errdefer helpers.reportFailure(backend);

        if (backend.kind == .openssl) {
            try expectDecryption(backend, null, &plain_hmac);
        }
        try expectDecryption(backend, "aes-128-cbc", &encrypted_hmac);
    }
}

test "CBC HMAC verification succeeds" {
    for (helpers.backends()) |backend| {
        errdefer helpers.reportFailure(backend);

        if (backend.kind == .openssl) {
            try expectVerification(backend, &plain_hmac);
        }
        try expectVerification(backend, &encrypted_hmac);
    }
}

fn expectEncryption(
    backend: helpers.Backend,
    cipher_name: ?[*:0]const u8,
    expected: []const u8,
) !void {
    const functions = backend.functions.enc;
    const context = functions.cbc_create.?(
        cipher_name,
        "sha256",
        null,
    ) orelse return error.CryptoCreationFailed;
    defer functions.cbc_free.?(context);

    var cipher_key_bytes: [32]u8 = @splat(0);
    var hmac_key_bytes: [32]u8 = @splat(0);
    var cipher_key = helpers.zeroingData(&cipher_key_bytes);
    var hmac_key = helpers.zeroingData(&hmac_key_bytes);
    c.pp_crypto_configure_encrypt(
        context,
        if (cipher_name != null) &cipher_key else null,
        &hmac_key,
    );

    var crypto_flags = helpers.flags(&.{}, &.{});
    var output: [plain.len + 256]u8 = @splat(0);
    const encrypted = try helpers.encrypt(context, &plain, &crypto_flags, &output);
    try std.testing.expectEqualSlices(u8, expected, encrypted);
}

fn expectDecryption(
    backend: helpers.Backend,
    cipher_name: ?[*:0]const u8,
    encrypted: []const u8,
) !void {
    const functions = backend.functions.enc;
    const context = functions.cbc_create.?(
        cipher_name,
        "sha256",
        null,
    ) orelse return error.CryptoCreationFailed;
    defer functions.cbc_free.?(context);

    var cipher_key_bytes: [32]u8 = @splat(0);
    var hmac_key_bytes: [32]u8 = @splat(0);
    var cipher_key = helpers.zeroingData(&cipher_key_bytes);
    var hmac_key = helpers.zeroingData(&hmac_key_bytes);
    c.pp_crypto_configure_decrypt(
        context,
        if (cipher_name != null) &cipher_key else null,
        &hmac_key,
    );

    var crypto_flags = helpers.flags(&.{}, &.{});
    var output: [encrypted_hmac.len + 256]u8 = @splat(0);
    const decrypted = try helpers.decrypt(context, encrypted, &crypto_flags, &output);
    try std.testing.expectEqualSlices(u8, &plain, decrypted);
}

fn expectVerification(backend: helpers.Backend, authenticated: []const u8) !void {
    const functions = backend.functions.enc;
    const context = functions.cbc_create.?(
        null,
        "sha256",
        null,
    ) orelse return error.CryptoCreationFailed;
    defer functions.cbc_free.?(context);

    var hmac_key_bytes: [32]u8 = @splat(0);
    var hmac_key = helpers.zeroingData(&hmac_key_bytes);
    c.pp_crypto_configure_decrypt(context, null, &hmac_key);

    try helpers.verify(context, authenticated);
}
