/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto.h"
#include "portable/zd.h"

crypto_ctx _Nullable crypto_aead_create(const char *_Nonnull cipher_name,
                                        size_t tag_len, size_t id_len,
                                        const crypto_keys_t *_Nullable keys);
void crypto_aead_free(crypto_ctx _Nonnull ctx);
