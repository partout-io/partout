/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "portable/common.h"
#include "portable/zd.h"

bool pp_crypto_init_seed(const uint8_t *_Nonnull src, const size_t len);
bool pp_crypto_init_seed_zd(const pp_zd *_Nonnull zd);

typedef enum {
    PPCryptoErrorNone,
    PPCryptoErrorEncryption,
    PPCryptoErrorHMAC
} pp_crypto_error_code;

typedef struct {
    const pp_zd *_Nonnull enc_key;
    const pp_zd *_Nonnull dec_key;
} pp_crypto_key_pair;

typedef struct {
    pp_crypto_key_pair cipher;
    pp_crypto_key_pair hmac;
} pp_crypto_keys;

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
} pp_crypto_flags;

typedef void (*pp_crypto_configure_fn)(void *_Nonnull ctx,
                                    const pp_zd *_Nullable cipher_key,
                                    const pp_zd *_Nullable hmac_key);

typedef size_t (*pp_crypto_encrypt_fn)(void *_Nonnull ctx,
                                    uint8_t *_Nonnull out, size_t out_buf_len,
                                    const uint8_t *_Nonnull in, size_t in_len,
                                    const pp_crypto_flags *_Nullable flags,
                                    pp_crypto_error_code *_Nullable error);

typedef size_t (*pp_crypto_decrypt_fn)(void *_Nonnull ctx,
                                    uint8_t *_Nonnull out, size_t out_buf_len,
                                    const uint8_t *_Nonnull in, size_t in_len,
                                    const pp_crypto_flags *_Nullable flags,
                                    pp_crypto_error_code *_Nullable error);

typedef bool (*pp_crypto_verify_fn)(void *_Nonnull ctx,
                                 const uint8_t *_Nonnull in, size_t in_len,
                                 pp_crypto_error_code *_Nullable error);

typedef struct {
    pp_crypto_configure_fn _Nonnull configure;
    pp_crypto_encrypt_fn _Nonnull encrypt;
} pp_crypto_encrypter;

typedef struct {
    pp_crypto_configure_fn _Nonnull configure;
    pp_crypto_decrypt_fn _Nonnull decrypt;
    pp_crypto_verify_fn _Nonnull verify;
} pp_crypto_decrypter;

typedef size_t (*pp_crypto_capacity_fn)(const void *_Nonnull ctx, size_t len);

typedef struct {
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t hmac_key_len;
    size_t digest_len;
    size_t tag_len;
    pp_crypto_capacity_fn _Nonnull encryption_capacity;
} pp_crypto_meta;

typedef struct {
    pp_crypto_meta meta;
    pp_crypto_encrypter encrypter;
    pp_crypto_decrypter decrypter;
} pp_crypto;

typedef struct {
    pp_crypto base;
} *pp_crypto_ctx;

typedef void (*pp_crypto_free_fn)(pp_crypto_ctx _Nonnull);

#ifndef MAX
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#endif

#ifndef MIN
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif

static inline
size_t pp_crypto_encryption_capacity(pp_crypto_ctx _Nonnull ctx, size_t len) {
    return ctx->base.meta.encryption_capacity(&ctx->base, len);
}

static inline
void pp_crypto_configure_encrypt(pp_crypto_ctx _Nonnull ctx,
                              const pp_zd *_Nullable cipher_key,
                              const pp_zd *_Nullable hmac_key) {

    ctx->base.encrypter.configure(&ctx->base, cipher_key, hmac_key);
}

static inline
size_t pp_crypto_encrypt(pp_crypto_ctx _Nonnull ctx,
                      uint8_t *_Nonnull out, size_t out_buf_len,
                      const uint8_t *_Nonnull in, size_t in_len,
                      const pp_crypto_flags *_Nullable flags, pp_crypto_error_code *_Nullable error) {

    return ctx->base.encrypter.encrypt(&ctx->base, out, out_buf_len, in, in_len, flags, error);
}

static inline
void pp_crypto_configure_decrypt(pp_crypto_ctx _Nonnull ctx,
                              const pp_zd *_Nullable cipher_key,
                              const pp_zd *_Nullable hmac_key) {

    ctx->base.decrypter.configure(&ctx->base, cipher_key, hmac_key);
}

static inline
size_t pp_crypto_decrypt(pp_crypto_ctx _Nonnull ctx,
                      uint8_t *_Nonnull out, size_t out_buf_len,
                      const uint8_t *_Nonnull in, size_t in_len,
                      const pp_crypto_flags *_Nullable flags, pp_crypto_error_code *_Nullable error) {

    return ctx->base.decrypter.decrypt(&ctx->base, out, out_buf_len, in, in_len, flags, error);
}

static inline
bool pp_crypto_verify(pp_crypto_ctx _Nonnull ctx,
                   const uint8_t *_Nonnull in, size_t in_len,
                   pp_crypto_error_code *_Nullable error) {

    pp_assert(ctx->base.decrypter.verify);
    return ctx->base.decrypter.verify(&ctx->base, in, in_len, error);
}

static inline
pp_crypto_meta pp_crypto_meta_of(pp_crypto_ctx _Nonnull ctx) {
    return ctx->base.meta;
}

static inline
void pp_assert_encryption_length(size_t out_len, size_t in_len) {
    const size_t out_min_len = pp_alloc_crypto_capacity(in_len, 0);
    pp_assert(out_len >= out_min_len);
}

static inline
void pp_assert_decryption_length(size_t out_len, size_t in_len) {
    pp_assert(out_len >= in_len);
}
