/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"

#pragma clang assume_nonnull begin

bool pp_darwin_crypto_init_seed(const uint8_t *src,
                                const size_t len);

pp_crypto_ctx _Nullable pp_darwin_crypto_aead_create(const char *cipher_name,
                                                     size_t tag_len,
                                                     size_t id_len,
                                                     const pp_crypto_keys *_Nullable keys);
void pp_darwin_crypto_aead_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_darwin_crypto_cbc_create(const char *_Nullable cipher_name,
                                                    const char *digest_name,
                                                    const pp_crypto_keys *_Nullable keys);
void pp_darwin_crypto_cbc_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_darwin_crypto_ctr_create(const char *cipher_name,
                                                    const char *digest_name,
                                                    size_t tag_len,
                                                    size_t payload_len,
                                                    const pp_crypto_keys *_Nullable keys);
void pp_darwin_crypto_ctr_free(pp_crypto_ctx ctx);

#pragma clang assume_nonnull end

pp_crypto_function_table pp_crypto_function_table_native_darwin(void) {
    const pp_enc_function_table enc = {
        .init_seed = pp_darwin_crypto_init_seed,
        .aead_create = pp_darwin_crypto_aead_create,
        .aead_free = pp_darwin_crypto_aead_free,
        .cbc_create = pp_darwin_crypto_cbc_create,
        .cbc_free = pp_darwin_crypto_cbc_free,
        .ctr_create = pp_darwin_crypto_ctr_create,
        .ctr_free = pp_darwin_crypto_ctr_free
    };
    pp_crypto_function_table table = pp_crypto_function_table_mbed();
    table.name = "native-darwin";
    table.enc = enc;
    return table;
}
