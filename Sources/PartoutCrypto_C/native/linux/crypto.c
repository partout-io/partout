/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/crypto.h"

#pragma clang assume_nonnull begin

bool pp_mbed_crypto_init_seed(const uint8_t *src,
                              const size_t len);

pp_crypto_ctx _Nullable pp_mbed_crypto_aead_create(const char *cipher_name,
                                                   size_t tag_len,
                                                   size_t id_len,
                                                   const pp_crypto_keys *_Nullable keys);
void pp_mbed_crypto_aead_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_mbed_crypto_cbc_create(const char *_Nullable cipher_name,
                                                  const char *digest_name,
                                                  const pp_crypto_keys *_Nullable keys);
void pp_mbed_crypto_cbc_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_mbed_crypto_ctr_create(const char *cipher_name,
                                                  const char *digest_name,
                                                  size_t tag_len,
                                                  size_t payload_len,
                                                  const pp_crypto_keys *_Nullable keys);
void pp_mbed_crypto_ctr_free(pp_crypto_ctx ctx);

#pragma clang assume_nonnull end

bool pp_crypto_init_seed(const uint8_t *src, const size_t len) {
    return pp_mbed_crypto_init_seed(src, len);
}

pp_crypto_ctx pp_crypto_aead_create(const char *cipher_name,
                                    size_t tag_len,
                                    size_t id_len,
                                    const pp_crypto_keys *keys) {
    return pp_mbed_crypto_aead_create(cipher_name, tag_len, id_len, keys);
}

void pp_crypto_aead_free(pp_crypto_ctx ctx) {
    pp_mbed_crypto_aead_free(ctx);
}

pp_crypto_ctx pp_crypto_cbc_create(const char *cipher_name,
                                   const char *digest_name,
                                   const pp_crypto_keys *keys) {
    return pp_mbed_crypto_cbc_create(cipher_name, digest_name, keys);
}

void pp_crypto_cbc_free(pp_crypto_ctx ctx) {
    pp_mbed_crypto_cbc_free(ctx);
}

pp_crypto_ctx pp_crypto_ctr_create(const char *cipher_name,
                                   const char *digest_name,
                                   size_t tag_len,
                                   size_t payload_len,
                                   const pp_crypto_keys *keys) {
    return pp_mbed_crypto_ctr_create(cipher_name, digest_name, tag_len, payload_len, keys);
}

void pp_crypto_ctr_free(pp_crypto_ctx ctx) {
    pp_mbed_crypto_ctr_free(ctx);
}
