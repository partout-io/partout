/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto.h"

typedef struct {
    crypto_t crypto;
} crypto_mock_t;

crypto_ctx _Nonnull crypto_mock_create();
void crypto_mock_free(crypto_ctx _Nonnull ctx);
