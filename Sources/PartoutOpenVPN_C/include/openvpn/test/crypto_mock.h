/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto.h"

typedef struct {
    pp_crypto crypto;
} openvpn_crypto_mock;

pp_crypto_ctx _Nonnull openvpn_crypto_mock_create();
void openvpn_crypto_mock_free(pp_crypto_ctx _Nonnull ctx);
