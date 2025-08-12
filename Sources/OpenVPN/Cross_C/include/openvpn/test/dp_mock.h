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
openvpn_dp_mode *_Nonnull openvpn_dp_mode_ad_create_mock(openvpn_compression_framing comp_f) {
    pp_crypto_ctx mock = openvpn_crypto_mock_create();
    return openvpn_dp_mode_ad_create(mock, openvpn_crypto_mock_free, comp_f);
}

static inline
openvpn_dp_mode *_Nullable openvpn_dp_mode_ad_create_aead(const char *_Nonnull cipher,
                                            size_t tag_len, size_t id_len,
                                            const pp_crypto_keys *_Nullable keys,
                                            openvpn_compression_framing comp_f) {
    pp_crypto_ctx crypto = pp_crypto_aead_create(cipher, tag_len, id_len, keys);
    if (!crypto) {
        return NULL;
    }
    return openvpn_dp_mode_ad_create(crypto, pp_crypto_aead_free, comp_f);
}

static inline
openvpn_dp_mode *_Nonnull openvpn_dp_mode_hmac_create_mock(openvpn_compression_framing comp_f) {
    pp_crypto_ctx mock = openvpn_crypto_mock_create();
    return openvpn_dp_mode_hmac_create(mock, openvpn_crypto_mock_free, comp_f);
}

static inline
openvpn_dp_mode *_Nullable openvpn_dp_mode_hmac_create_cbc(const char *_Nullable cipher,
                                             const char *_Nonnull digest,
                                             const pp_crypto_keys *_Nullable keys,
                                             openvpn_compression_framing comp_f) {
    pp_crypto_ctx crypto = pp_crypto_cbc_create(cipher, digest, keys);
    if (!crypto) {
        return NULL;
    }
    return openvpn_dp_mode_hmac_create(crypto, pp_crypto_cbc_free, comp_f);
}
