/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#define CRYPTO_ASSERT(ossl_code) pp_assert(ossl_code > 0);

#define CRYPTO_CHECK(ossl_code)\
if (ossl_code <= 0) {\
    if (error) *error = CryptoErrorEncryption;\
    return 0;\
}

#define CRYPTO_CHECK_MAC(ossl_code)\
if (ossl_code <= 0) {\
    if (error) *error = CryptoErrorHMAC;\
    EVP_MAC_CTX_free(mac_ctx);\
    return 0;\
}

#define CRYPTO_SET_ERROR(pp_crypto_code)\
if (error) *error = pp_crypto_code;\
