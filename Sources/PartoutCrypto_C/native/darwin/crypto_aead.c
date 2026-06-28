/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/crypto_base.h"

#pragma clang assume_nonnull begin

pp_crypto_ctx _Nullable pp_mbed_crypto_aead_create(const char *cipher_name,
                                                   size_t tag_len,
                                                   size_t id_len,
                                                   const pp_crypto_keys *_Nullable keys);
void pp_mbed_crypto_aead_free(pp_crypto_ctx ctx);

#pragma clang assume_nonnull end

pp_crypto_ctx pp_darwin_crypto_aead_create(const char *cipher_name,
                                           size_t tag_len,
                                           size_t id_len,
                                           const pp_crypto_keys *keys) {
    return pp_mbed_crypto_aead_create(cipher_name, tag_len, id_len, keys);
}

void pp_darwin_crypto_aead_free(pp_crypto_ctx ctx) {
    pp_mbed_crypto_aead_free(ctx);
}
