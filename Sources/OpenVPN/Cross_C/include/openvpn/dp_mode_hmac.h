/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "openvpn/dp_mode.h"

// WARNING: retains crypto
dp_mode_t *_Nonnull dp_mode_hmac_create(crypto_ctx _Nonnull crypto,
                                        crypto_free_fn _Nonnull crypto_free,
                                        compression_framing_t comp_f);
