/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto_base.h"

#define PP_CRYPTO_ASSERT(ntstatus) pp_assert(BCRYPT_SUCCESS(ntstatus));

#define PP_CRYPTO_CHECK_CREATE(ntstatus) if (!BCRYPT_SUCCESS(ntstatus)) goto failure;

#define PP_CRYPTO_CHECK(ntstatus)\
if (!BCRYPT_SUCCESS(ntstatus)) {\
    if (error) *error = PPCryptoErrorEncryption;\
    return 0;\
}

#define PP_CRYPTO_CHECK_MAC(ntstatus)\
if (!BCRYPT_SUCCESS(ntstatus)) {\
    if (error) *error = PPCryptoErrorHMAC;\
    if (hHmac) BCryptDestroyHash(hHmac);\
    return 0;\
}

#define PP_CRYPTO_CHECK_MAC_ALG(ntstatus)\
if (!BCRYPT_SUCCESS(ntstatus)) {\
    if (error) *error = PPCryptoErrorHMAC;\
    if (hHmac) BCryptDestroyHash(hHmac);\
    if (hAlgHmac) BCryptCloseAlgorithmProvider(hAlgHmac, 0);\
    return 0;\
}

#define PP_CRYPTO_SET_ERROR(crypto_code)\
if (error) *error = crypto_code;\

#pragma clang assume_nonnull begin

bool pp_windows_crypto_init_seed(const uint8_t *src,
                                 const size_t len);

pp_crypto_ctx _Nullable pp_windows_crypto_aead_create(const char *cipher_name,
                                                      size_t tag_len,
                                                      size_t id_len,
                                                      const pp_crypto_keys *_Nullable keys);
void pp_windows_crypto_aead_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_windows_crypto_cbc_create(const char *_Nullable cipher_name,
                                                     const char *digest_name,
                                                     const pp_crypto_keys *_Nullable keys);
void pp_windows_crypto_cbc_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_windows_crypto_ctr_create(const char *cipher_name,
                                                     const char *digest_name,
                                                     size_t tag_len,
                                                     size_t payload_len,
                                                     const pp_crypto_keys *_Nullable keys);
void pp_windows_crypto_ctr_free(pp_crypto_ctx ctx);

#pragma clang assume_nonnull end
