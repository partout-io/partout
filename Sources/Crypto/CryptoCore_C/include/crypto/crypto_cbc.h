/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto.h"
#include "crypto/zeroing_data.h"

crypto_ctx _Nullable crypto_cbc_create(const char *_Nullable cipher_name,
                                       const char *_Nonnull digest_name,
                                       const crypto_keys_t *_Nullable keys);
void crypto_cbc_free(crypto_ctx _Nonnull ctx);
