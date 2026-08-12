/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/function_table.h"

#define PP_CRYPTO_ASSERT(ossl_code) pp_assert(ossl_code > 0);

#define PP_CRYPTO_CHECK(ossl_code)\
if (ossl_code <= 0) {\
    if (error) *error = PPCryptoErrorEncryption;\
    return 0;\
}

#define PP_CRYPTO_CHECK_MAC(ossl_code)\
if (ossl_code <= 0) {\
    if (error) *error = PPCryptoErrorHMAC;\
    EVP_MAC_CTX_free(mac_ctx);\
    return 0;\
}

#define PP_CRYPTO_SET_ERROR(crypto_code)\
if (error) *error = crypto_code;\

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
