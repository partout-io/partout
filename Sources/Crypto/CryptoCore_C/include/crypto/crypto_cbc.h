/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto.h"
#include "portable/zd.h"

pp_crypto_ctx _Nullable pp_crypto_cbc_create(const char *_Nullable cipher_name,
                                       const char *_Nonnull digest_name,
                                       const pp_crypto_keys_t *_Nullable keys);
void pp_crypto_cbc_free(pp_crypto_ctx _Nonnull ctx);
