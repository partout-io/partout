/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "openvpn/dp_mode.h"

#pragma clang assume_nonnull begin

// WARNING: retains crypto
openvpn_dp_mode *openvpn_dp_mode_hmac_create(pp_crypto_ctx crypto,
                                             pp_crypto_free_fn pp_crypto_free,
                                             openvpn_compression_framing comp_f);

#pragma clang assume_nonnull end
