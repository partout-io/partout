/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "openvpn/dp_mode_ad.h"
#include "openvpn/dp_mode_hmac.h"

#pragma clang assume_nonnull begin

static inline
openvpn_dp_mode *_Nullable openvpn_dp_mode_ad_create_aead(const pp_crypto_enc_fnt *fnt,
                                                          const char *cipher,
                                                          size_t tag_len, size_t id_len,
                                                          const pp_crypto_keys *_Nullable keys,
                                                          openvpn_compression_framing comp_f) {
    pp_crypto_ctx crypto = fnt->aead_create(cipher, tag_len, id_len, keys);
    if (!crypto) {
        return NULL;
    }
    return openvpn_dp_mode_ad_create(crypto, fnt->aead_free, comp_f);
}

static inline
openvpn_dp_mode *_Nullable openvpn_dp_mode_hmac_create_cbc(const pp_crypto_enc_fnt *fnt,
                                                           const char *_Nullable cipher,
                                                           const char *digest,
                                                           const pp_crypto_keys *_Nullable keys,
                                                           openvpn_compression_framing comp_f) {
    pp_crypto_ctx crypto = fnt->cbc_create(cipher, digest, keys);
    if (!crypto) {
        return NULL;
    }
    return openvpn_dp_mode_hmac_create(crypto, fnt->cbc_free, comp_f);
}

#pragma clang assume_nonnull end
