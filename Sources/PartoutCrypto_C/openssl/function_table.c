/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto_openssl.h"

pp_crypto_fnt pp_crypto_fnt_openssl(void) {
    pp_crypto_fnt table = {
        .name = "openssl",

        .enc = {
            .init_seed = pp_openssl_crypto_init_seed,
            .aead_create = pp_openssl_crypto_aead_create,
            .aead_free = pp_openssl_crypto_aead_free,
            .cbc_create = pp_openssl_crypto_cbc_create,
            .cbc_free = pp_openssl_crypto_cbc_free,
            .ctr_create = pp_openssl_crypto_ctr_create,
            .ctr_free = pp_openssl_crypto_ctr_free
        },

        .hmac_do = pp_openssl_hmac_do,

        .key_decrypted_from_path = pp_openssl_key_decrypted_from_path,
        .key_decrypted_from_pem = pp_openssl_key_decrypted_from_pem,

        .tls = {
            .create = pp_openssl_tls_create,
            .free = pp_openssl_tls_free,
            .start = pp_openssl_tls_start,
            .is_connected = pp_openssl_tls_is_connected,
            .pull_cipher = pp_openssl_tls_pull_cipher,
            .pull_plain = pp_openssl_tls_pull_plain,
            .put_cipher = pp_openssl_tls_put_cipher,
            .put_plain = pp_openssl_tls_put_plain,
            .ca_md5 = pp_openssl_tls_ca_md5
        }
    };
    return table;
}
