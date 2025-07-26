/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto_aead.h"
#include "crypto/crypto_cbc.h"
#include "openvpn/dp_mode_ad.h"
#include "openvpn/test/crypto_mock.h"

static inline
dp_mode_t *_Nonnull dp_mode_ad_create_mock(compression_framing_t comp_f) {
    crypto_ctx mock = crypto_mock_create();
    return dp_mode_ad_create(mock, crypto_mock_free, comp_f);
}

static inline
dp_mode_t *_Nullable dp_mode_ad_create_aead(const char *_Nonnull cipher,
                                            size_t tag_len, size_t id_len,
                                            const crypto_keys_t *_Nullable keys,
                                            compression_framing_t comp_f) {
    crypto_ctx crypto = crypto_aead_create(cipher, tag_len, id_len, keys);
    if (!crypto) {
        return NULL;
    }
    return dp_mode_ad_create(crypto, crypto_aead_free, comp_f);
}

static inline
dp_mode_t *_Nonnull dp_mode_hmac_create_mock(compression_framing_t comp_f) {
    crypto_ctx mock = crypto_mock_create();
    return dp_mode_hmac_create(mock, crypto_mock_free, comp_f);
}

static inline
dp_mode_t *_Nullable dp_mode_hmac_create_cbc(const char *_Nullable cipher,
                                             const char *_Nonnull digest,
                                             const crypto_keys_t *_Nullable keys,
                                             compression_framing_t comp_f) {
    crypto_ctx crypto = crypto_cbc_create(cipher, digest, keys);
    if (!crypto) {
        return NULL;
    }
    return dp_mode_hmac_create(crypto, crypto_cbc_free, comp_f);
}
