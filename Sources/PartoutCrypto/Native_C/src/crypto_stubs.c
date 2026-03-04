/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

// FIXME: #108, Implement on Apple (CommonCrypto), Linux, Android

#ifndef _WIN32

#include "crypto/crypto.h"
#include "crypto/hmac.h"

pp_crypto_ctx pp_crypto_aead_create(const char *cipher_name,
                                    size_t tag_len, size_t id_len,
                                    const pp_crypto_keys *keys) {
    return NULL;
}

void pp_crypto_aead_free(pp_crypto_ctx vctx) {}

pp_crypto_ctx pp_crypto_cbc_create(const char *cipher_name,
                                   const char *_Nonnull digest_name,
                                   const pp_crypto_keys *keys) {
    return NULL;
}

void pp_crypto_cbc_free(pp_crypto_ctx vctx) {}

pp_crypto_ctx pp_crypto_ctr_create(const char *cipher_name,
                                   const char *_Nonnull digest_name,
                                   size_t tag_len, size_t payload_len,
                                   const pp_crypto_keys *keys) {
    return NULL;
}

void pp_crypto_ctr_free(pp_crypto_ctx vctx) {}

bool pp_crypto_init_seed(const uint8_t *_Nonnull src, const size_t len) {
    return false;
}

pp_zd *pp_hmac_create() {
    return NULL;
}

size_t pp_hmac_do(pp_hmac_ctx *_Nonnull ctx) {
    return 0;
}

#endif
