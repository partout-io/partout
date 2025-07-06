//
//  crypto.h
//  Partout
//
//  Created by Davide De Rosa on 6/14/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

#pragma once

#include "crypto/zeroing_data.h"

typedef enum {
    CryptoErrorNone,
    CryptoErrorEncryption,
    CryptoErrorHMAC
} crypto_error_code;

typedef struct {
    const zeroing_data_t *_Nonnull enc_key;
    const zeroing_data_t *_Nonnull dec_key;
} crypto_key_pair_t;

typedef struct {
    crypto_key_pair_t cipher;
    crypto_key_pair_t hmac;
} crypto_keys_t;

/// Custom flags for encryption routines.
typedef struct {

    /// A custom initialization vector (IV).
    const uint8_t *_Nullable iv;

    /// The length of ``iv``.
    size_t iv_len;

    /// A custom associated data for AEAD (AD).
    const uint8_t *_Nullable ad;

    /// The length of ``ad``.
    size_t ad_len;

    /// Enable testable (predictable) behavior.
    int for_testing;
} crypto_flags_t;

typedef void (*crypto_configure_fn)(void *_Nonnull ctx,
                                    const zeroing_data_t *_Nullable cipher_key,
                                    const zeroing_data_t *_Nullable hmac_key);

typedef size_t (*crypto_encrypt_fn)(void *_Nonnull ctx,
                                    uint8_t *_Nonnull out, size_t out_buf_len,
                                    const uint8_t *_Nonnull in, size_t in_len,
                                    const crypto_flags_t *_Nullable flags,
                                    crypto_error_code *_Nullable error);

typedef size_t (*crypto_decrypt_fn)(void *_Nonnull ctx,
                                    uint8_t *_Nonnull out, size_t out_buf_len,
                                    const uint8_t *_Nonnull in, size_t in_len,
                                    const crypto_flags_t *_Nullable flags,
                                    crypto_error_code *_Nullable error);

typedef bool (*crypto_verify_fn)(void *_Nonnull ctx,
                                 const uint8_t *_Nonnull in, size_t in_len,
                                 crypto_error_code *_Nullable error);

typedef struct {
    crypto_configure_fn _Nonnull configure;
    crypto_encrypt_fn _Nonnull encrypt;
} crypto_encrypter_t;

typedef struct {
    crypto_configure_fn _Nonnull configure;
    crypto_decrypt_fn _Nonnull decrypt;
    crypto_verify_fn _Nonnull verify;
} crypto_decrypter_t;

typedef size_t (*crypto_capacity_fn)(const void *_Nonnull ctx, size_t len);

typedef struct {
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t hmac_key_len;
    size_t digest_len;
    size_t tag_len;
    crypto_capacity_fn _Nonnull encryption_capacity;
} crypto_meta_t;

typedef struct {
    crypto_meta_t meta;
    crypto_encrypter_t encrypter;
    crypto_decrypter_t decrypter;
} crypto_t;

typedef struct {
    crypto_t base;
} *crypto_ctx;

typedef void (*crypto_free_fn)(crypto_ctx _Nonnull);

#ifndef MAX
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#endif

#ifndef MIN
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif

static inline
size_t crypto_encryption_capacity(crypto_ctx _Nonnull ctx, size_t len) {
    return ctx->base.meta.encryption_capacity(&ctx->base, len);
}

static inline
void crypto_configure_encrypt(crypto_ctx _Nonnull ctx,
                              const zeroing_data_t *_Nullable cipher_key,
                              const zeroing_data_t *_Nullable hmac_key) {

    ctx->base.encrypter.configure(&ctx->base, cipher_key, hmac_key);
}

static inline
size_t crypto_encrypt(crypto_ctx _Nonnull ctx,
                      uint8_t *_Nonnull out, size_t out_buf_len,
                      const uint8_t *_Nonnull in, size_t in_len,
                      const crypto_flags_t *_Nullable flags, crypto_error_code *_Nullable error) {

    return ctx->base.encrypter.encrypt(&ctx->base, out, out_buf_len, in, in_len, flags, error);
}

static inline
void crypto_configure_decrypt(crypto_ctx _Nonnull ctx,
                              const zeroing_data_t *_Nullable cipher_key,
                              const zeroing_data_t *_Nullable hmac_key) {

    ctx->base.decrypter.configure(&ctx->base, cipher_key, hmac_key);
}

static inline
size_t crypto_decrypt(crypto_ctx _Nonnull ctx,
                      uint8_t *_Nonnull out, size_t out_buf_len,
                      const uint8_t *_Nonnull in, size_t in_len,
                      const crypto_flags_t *_Nullable flags, crypto_error_code *_Nullable error) {

    return ctx->base.decrypter.decrypt(&ctx->base, out, out_buf_len, in, in_len, flags, error);
}

static inline
bool crypto_verify(crypto_ctx _Nonnull ctx,
                   const uint8_t *_Nonnull in, size_t in_len,
                   crypto_error_code *_Nullable error) {

    assert(ctx->base.decrypter.verify);
    return ctx->base.decrypter.verify(&ctx->base, in, in_len, error);
}

static inline
crypto_meta_t crypto_meta(crypto_ctx _Nonnull ctx) {
    return ctx->base.meta;
}
