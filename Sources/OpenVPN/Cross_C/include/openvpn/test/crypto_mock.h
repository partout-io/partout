/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto.h"

typedef struct {
    pp_crypto_t crypto;
} pp_crypto_mock_t;

pp_crypto_ctx _Nonnull pp_crypto_mock_create();
void pp_crypto_mock_free(pp_crypto_ctx _Nonnull ctx);
