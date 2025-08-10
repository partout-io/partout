/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto.h"
#include "portable/zd.h"

crypto_ctx _Nullable crypto_ctr_create(const char *_Nonnull cipher_name,
                                       const char *_Nonnull digest_name,
                                       size_t tag_len, size_t payload_len,
                                       const crypto_keys_t *_Nullable keys);
void crypto_ctr_free(crypto_ctx _Nonnull ctx);
