/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "openvpn/dp_mode.h"

// WARNING: retains crypto
openvpn_dp_mode *_Nonnull openvpn_dp_mode_ad_create(pp_crypto_ctx _Nonnull crypto,
                                                    pp_crypto_free_fn _Nonnull pp_crypto_free,
                                                    openvpn_compression_framing comp_f,
                                                    bool with_lzo);
