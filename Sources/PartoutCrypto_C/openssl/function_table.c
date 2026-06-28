/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"

#pragma clang assume_nonnull begin

bool pp_openssl_crypto_init_seed(const uint8_t *src,
                                 const size_t len);

pp_crypto_ctx _Nullable pp_openssl_crypto_aead_create(const char *cipher_name,
                                                      size_t tag_len,
                                                      size_t id_len,
                                                      const pp_crypto_keys *_Nullable keys);
void pp_openssl_crypto_aead_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_openssl_crypto_cbc_create(const char *_Nullable cipher_name,
                                                     const char *digest_name,
                                                     const pp_crypto_keys *_Nullable keys);
void pp_openssl_crypto_cbc_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_openssl_crypto_ctr_create(const char *cipher_name,
                                                     const char *digest_name,
                                                     size_t tag_len,
                                                     size_t payload_len,
                                                     const pp_crypto_keys *_Nullable keys);
void pp_openssl_crypto_ctr_free(pp_crypto_ctx ctx);

size_t pp_openssl_hmac_do(pp_hmac_ctx *ctx);

char *_Nullable pp_openssl_key_decrypted_from_path(const char *path,
                                                   const char *passphrase);
char *_Nullable pp_openssl_key_decrypted_from_pem(const char *pem,
                                                  const char *passphrase);

pp_tls _Nullable pp_openssl_tls_create(const pp_tls_options *opt,
                                       pp_tls_error_code *error);
void pp_openssl_tls_free(pp_tls tls);
bool pp_openssl_tls_start(pp_tls tls);
bool pp_openssl_tls_is_connected(pp_tls tls);
pp_zd *_Nullable pp_openssl_tls_pull_cipher(pp_tls tls,
                                            pp_tls_error_code *_Nullable error);
pp_zd *_Nullable pp_openssl_tls_pull_plain(pp_tls tls,
                                           pp_tls_error_code *_Nullable error);
bool pp_openssl_tls_put_cipher(pp_tls tls,
                               const uint8_t *src,
                               size_t src_len,
                               pp_tls_error_code *_Nullable error);
bool pp_openssl_tls_put_plain(pp_tls tls,
                              const uint8_t *src,
                              size_t src_len,
                              pp_tls_error_code *_Nullable error);
char *_Nullable pp_openssl_tls_ca_md5(const pp_tls tls);

#pragma clang assume_nonnull end

const pp_crypto_function_table pp_crypto_function_table_openssl = {
    .name = "openssl",

    .init_seed = pp_openssl_crypto_init_seed,

    .aead_create = pp_openssl_crypto_aead_create,
    .aead_free = pp_openssl_crypto_aead_free,

    .cbc_create = pp_openssl_crypto_cbc_create,
    .cbc_free = pp_openssl_crypto_cbc_free,

    .ctr_create = pp_openssl_crypto_ctr_create,
    .ctr_free = pp_openssl_crypto_ctr_free,

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
