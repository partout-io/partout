/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "openvpn/dp_mode_shortcuts.h"
#include "openvpn/test/crypto_mock.h"

static inline
openvpn_dp_mode *_Nonnull openvpn_dp_mode_ad_create_mock(openvpn_compression_framing comp_f) {
    pp_crypto_ctx mock = openvpn_crypto_mock_create();
    return openvpn_dp_mode_ad_create(mock, openvpn_crypto_mock_free, comp_f, false);
}

static inline
openvpn_dp_mode *_Nonnull openvpn_dp_mode_hmac_create_mock(openvpn_compression_framing comp_f) {
    pp_crypto_ctx mock = openvpn_crypto_mock_create();
    return openvpn_dp_mode_hmac_create(mock, openvpn_crypto_mock_free, comp_f, false);
}
