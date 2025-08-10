/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#define CRYPTO_ASSERT(ntstatus) pp_assert(BCRYPT_SUCCESS(ntstatus));

#define CRYPTO_CHECK_CREATE(ntstatus) if (!BCRYPT_SUCCESS(ntstatus)) goto failure;

#define CRYPTO_CHECK(ntstatus)\
if (!BCRYPT_SUCCESS(ntstatus)) {\
    if (error) *error = PPCryptoErrorEncryption;\
    return 0;\
}

#define CRYPTO_CHECK_MAC(ntstatus)\
if (!BCRYPT_SUCCESS(ntstatus)) {\
    if (error) *error = PPCryptoErrorHMAC;\
    if (hHmac) BCryptDestroyHash(hHmac);\
    return 0;\
}

#define CRYPTO_CHECK_MAC_ALG(ntstatus)\
if (!BCRYPT_SUCCESS(ntstatus)) {\
    if (error) *error = PPCryptoErrorHMAC;\
    if (hHmac) BCryptDestroyHash(hHmac);\
    if (hAlgHmac) BCryptCloseAlgorithmProvider(hAlgHmac, 0);\
    return 0;\
}

#define CRYPTO_SET_ERROR(crypto_code)\
if (error) *error = crypto_code;\
