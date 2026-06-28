/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto_base.h"
#include "crypto_aead.h"
#include "crypto_cbc.h"
#include "crypto_ctr.h"
#include "hmac.h"
#include "keys.h"
#include "tls.h"

#pragma clang assume_nonnull begin

typedef bool (*pp_crypto_init_seed_fn)(const uint8_t *src,
                                       const size_t len);

typedef pp_crypto_ctx _Nullable (*pp_crypto_aead_create_fn)(const char *cipher_name,
                                                            size_t tag_len,
                                                            size_t id_len,
                                                            const pp_crypto_keys *_Nullable keys);

typedef pp_crypto_ctx _Nullable (*pp_crypto_cbc_create_fn)(const char *_Nullable cipher_name,
                                                           const char *digest_name,
                                                           const pp_crypto_keys *_Nullable keys);

typedef pp_crypto_ctx _Nullable (*pp_crypto_ctr_create_fn)(const char *cipher_name,
                                                           const char *digest_name,
                                                           size_t tag_len,
                                                           size_t payload_len,
                                                           const pp_crypto_keys *_Nullable keys);

typedef size_t (*pp_hmac_do_fn)(pp_hmac_ctx *ctx);

typedef char *_Nullable (*pp_key_decrypted_from_path_fn)(const char *path,
                                                         const char *passphrase);

typedef char *_Nullable (*pp_key_decrypted_from_pem_fn)(const char *pem,
                                                        const char *passphrase);

typedef pp_tls _Nullable (*pp_tls_create_fn)(const pp_tls_options *opt,
                                             pp_tls_error_code *error);

typedef void (*pp_tls_free_fn)(pp_tls tls);

typedef bool (*pp_tls_start_fn)(pp_tls tls);

typedef bool (*pp_tls_is_connected_fn)(pp_tls tls);

typedef pp_zd *_Nullable (*pp_tls_pull_cipher_fn)(pp_tls tls,
                                                  pp_tls_error_code *_Nullable error);

typedef pp_zd *_Nullable (*pp_tls_pull_plain_fn)(pp_tls tls,
                                                 pp_tls_error_code *_Nullable error);

typedef bool (*pp_tls_put_cipher_fn)(pp_tls tls,
                                     const uint8_t *src,
                                     size_t src_len,
                                     pp_tls_error_code *_Nullable error);

typedef bool (*pp_tls_put_plain_fn)(pp_tls tls,
                                    const uint8_t *src,
                                    size_t src_len,
                                    pp_tls_error_code *_Nullable error);

typedef char *_Nullable (*pp_tls_ca_md5_fn)(const pp_tls tls);

typedef struct {
    pp_crypto_init_seed_fn init_seed;
} pp_crypto_base_function_table;

typedef struct {
    pp_crypto_aead_create_fn create;
    pp_crypto_free_fn free;
} pp_crypto_aead_function_table;

typedef struct {
    pp_crypto_cbc_create_fn create;
    pp_crypto_free_fn free;
} pp_crypto_cbc_function_table;

typedef struct {
    pp_crypto_ctr_create_fn create;
    pp_crypto_free_fn free;
} pp_crypto_ctr_function_table;

typedef struct {
    pp_hmac_do_fn do_hmac;
} pp_hmac_function_table;

typedef struct {
    pp_key_decrypted_from_path_fn decrypted_from_path;
    pp_key_decrypted_from_pem_fn decrypted_from_pem;
} pp_key_function_table;

typedef struct {
    pp_tls_create_fn create;
    pp_tls_free_fn free;
    pp_tls_start_fn start;
    pp_tls_is_connected_fn is_connected;
    pp_tls_pull_cipher_fn pull_cipher;
    pp_tls_pull_plain_fn pull_plain;
    pp_tls_put_cipher_fn put_cipher;
    pp_tls_put_plain_fn put_plain;
    pp_tls_ca_md5_fn ca_md5;
} pp_tls_function_table;

typedef struct {
    const char *name;
    pp_crypto_base_function_table base;
    pp_crypto_aead_function_table aead;
    pp_crypto_cbc_function_table cbc;
    pp_crypto_ctr_function_table ctr;
    pp_hmac_function_table hmac;
    pp_key_function_table keys;
    pp_tls_function_table tls;
} pp_crypto_function_table;

#pragma clang assume_nonnull end
