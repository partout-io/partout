// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const helpers = @import("helpers.zig");
const c = helpers.c;

const plain = helpers.hex("00112233ffddaa");
const expected_encrypted = helpers.hex("6c56b501472aae003fe988286ea3e72454d1dda1c2fd6c");
const iv = [_]u8{ 0x56, 0x34, 0x12, 0x00 };
const ad = [_]u8{ 0x00, 0x12, 0x34, 0x56 };

test "AEAD encryption matches the vector and decrypts" {
    for (helpers.backends()) |backend| {
        errdefer helpers.reportFailure(backend);

        const functions = backend.functions.enc;
        const context = functions.aead_create.?(
            "aes-256-gcm",
            16,
            4,
            null,
        ) orelse return error.CryptoCreationFailed;
        defer functions.aead_free.?(context);

        var cipher_key_bytes: [32]u8 = @splat(0);
        var hmac_key_bytes: [32]u8 = @splat(0);
        var cipher_key = helpers.zeroingData(&cipher_key_bytes);
        var hmac_key = helpers.zeroingData(&hmac_key_bytes);
        c.pp_crypto_configure_encrypt(context, &cipher_key, &hmac_key);
        c.pp_crypto_configure_decrypt(context, &cipher_key, &hmac_key);

        var crypto_flags = helpers.flags(&iv, &ad);
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
