/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto.h"

#pragma clang assume_nonnull begin

pp_crypto_ctx _Nullable pp_crypto_ctr_create(const char *cipher_name,
                                             const char *digest_name,
                                             size_t tag_len, size_t payload_len,
                                             const pp_crypto_keys *_Nullable keys);
void pp_crypto_ctr_free(pp_crypto_ctx ctx);

#pragma clang assume_nonnull end
