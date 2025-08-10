/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto.h"
#include "portable/zd.h"

pp_crypto_ctx _Nullable pp_crypto_aead_create(const char *_Nonnull cipher_name,
                                        size_t tag_len, size_t id_len,
                                        const pp_crypto_keys_t *_Nullable keys);
void pp_crypto_aead_free(pp_crypto_ctx _Nonnull ctx);
