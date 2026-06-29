/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto_base.h"
#include "hmac.h"
#include "keys.h"
#include "tls.h"

#pragma clang assume_nonnull begin

typedef struct {
    pp_crypto_init_seed_fn init_seed;
    pp_crypto_aead_create_fn aead_create;
    pp_crypto_free_fn aead_free;
    pp_crypto_cbc_create_fn cbc_create;
    pp_crypto_free_fn cbc_free;
    pp_crypto_ctr_create_fn ctr_create;
    pp_crypto_free_fn ctr_free;
} pp_enc_function_table;

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
    pp_enc_function_table enc;
    pp_hmac_do_fn hmac_do;
    pp_key_decrypted_from_path_fn key_decrypted_from_path;
    pp_key_decrypted_from_pem_fn key_decrypted_from_pem;
    pp_tls_function_table tls;
} pp_crypto_function_table;

pp_crypto_function_table pp_crypto_function_table_openssl(void);
pp_crypto_function_table pp_crypto_function_table_mbed(void);
pp_crypto_function_table pp_crypto_function_table_native(void);
pp_crypto_function_table pp_crypto_function_table_mock(void);

#pragma clang assume_nonnull end
