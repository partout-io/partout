/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto.h"
#include "crypto_aead_mbedtls_api.h"

#pragma clang assume_nonnull begin

bool pp_mbed_crypto_init_seed(const uint8_t *src, const size_t len);

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

char *_Nullable pp_mbed_key_decrypted_from_path(const char *path,
                                                const char *passphrase);
char *_Nullable pp_mbed_key_decrypted_from_pem(const char *pem,
                                               const char *passphrase);

pp_tls _Nullable pp_mbedtls_create(const pp_tls_options *opt,
                                    pp_tls_error_code *error);
void pp_mbedtls_free(pp_tls tls);
bool pp_mbedtls_start(pp_tls tls);
bool pp_mbedtls_is_connected(pp_tls tls);
pp_zd *_Nullable pp_mbedtls_pull_cipher(pp_tls tls,
                                         pp_tls_error_code *_Nullable error);
pp_zd *_Nullable pp_mbedtls_pull_plain(pp_tls tls,
                                        pp_tls_error_code *_Nullable error);
bool pp_mbedtls_put_cipher(pp_tls tls,
                            const uint8_t *src,
                            size_t src_len,
                            pp_tls_error_code *_Nullable error);
bool pp_mbedtls_put_plain(pp_tls tls,
                           const uint8_t *src,
                           size_t src_len,
                           pp_tls_error_code *_Nullable error);
char *_Nullable pp_mbedtls_ca_md5(const pp_tls tls);

#pragma clang assume_nonnull end
