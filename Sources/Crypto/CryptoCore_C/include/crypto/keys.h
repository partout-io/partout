/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "portable/zd.h"

bool key_init_seed(const pp_zd *_Nonnull zd);

typedef struct {
    pp_zd *_Nonnull dst;
    const char *_Nonnull digest_name;
    const pp_zd *_Nonnull secret;
    const pp_zd *_Nonnull data;
} key_hmac_ctx;

pp_zd *_Nonnull key_hmac_create();
size_t key_hmac_do(key_hmac_ctx *_Nonnull ctx);

char *_Nullable key_decrypted_from_path(const char *_Nonnull path,
                                        const char *_Nonnull passphrase);

char *_Nullable key_decrypted_from_pem(const char *_Nonnull pem,
                                       const char *_Nonnull passphrase);
