// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const helpers = @import("helpers.zig");
const crypto_c = helpers.crypto_c;

const plain = helpers.hex("00112233ffddaa");
const expected_encrypted = helpers.hex("2743c16b105670b350b6a5062224a0b691fb184c6d14dc0f39eed86aa04a1ca06b79108c65ed66");
const ad = [_]u8{ 0x00, 0x12, 0x34, 0x56 };

test "CTR encryption matches the vector and decrypts" {
    for (helpers.backends()) |backend| {
        errdefer helpers.reportFailure(backend);

        const functions = backend.functions.enc;
        const context = functions.ctr_create.?(
            "aes-128-ctr",
            "sha256",
            32,
            128,
            null,
        ) orelse return error.CryptoCreationFailed;
        defer functions.ctr_free.?(context);

        var cipher_key_bytes: [32]u8 = @splat(0);
        var hmac_key_bytes: [32]u8 = @splat(0);
        var cipher_key = helpers.zeroingData(&cipher_key_bytes);
        var hmac_key = helpers.zeroingData(&hmac_key_bytes);
        crypto_c.pp_crypto_configure_encrypt(context, &cipher_key, &hmac_key);
        crypto_c.pp_crypto_configure_decrypt(context, &cipher_key, &hmac_key);

        var crypto_flags = helpers.flags(&.{}, &ad);
        var encrypted_buffer: [plain.len + 256]u8 = @splat(0);
        const encrypted = try helpers.encrypt(
            context,
            &plain,
            &crypto_flags,
            &encrypted_buffer,
        );
        try std.testing.expectEqualSlices(u8, &expected_encrypted, encrypted);

        var decrypted_buffer: [expected_encrypted.len + 256]u8 = @splat(0);
        const decrypted = try helpers.decrypt(
            context,
            encrypted,
            &crypto_flags,
            &decrypted_buffer,
        );
        try std.testing.expectEqualSlices(u8, &plain, decrypted);
    }
}
