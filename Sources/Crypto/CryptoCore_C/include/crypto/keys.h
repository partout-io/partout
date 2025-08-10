/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "crypto/zeroing_data.h"

bool key_init_seed(const zeroing_data_t *_Nonnull zd);

typedef struct {
    zeroing_data_t *_Nonnull dst;
    const char *_Nonnull digest_name;
    const zeroing_data_t *_Nonnull secret;
    const zeroing_data_t *_Nonnull data;
} key_hmac_ctx;

zeroing_data_t *_Nonnull key_hmac_create();
size_t key_hmac_do(key_hmac_ctx *_Nonnull ctx);

char *_Nullable key_decrypted_from_path(const char *_Nonnull path,
                                        const char *_Nonnull passphrase);

char *_Nullable key_decrypted_from_pem(const char *_Nonnull pem,
                                       const char *_Nonnull passphrase);
