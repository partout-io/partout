/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>
#include "portable/zd.h"

typedef struct {
    uint8_t *_Nonnull dst;
    size_t dst_len;
    const char *_Nonnull digest_name;
    const uint8_t *_Nonnull secret;
    size_t secret_len;
    const uint8_t *_Nonnull data;
    size_t data_len;
} pp_hmac_ctx;

pp_zd *_Nonnull pp_hmac_create();
size_t pp_hmac_do(pp_hmac_ctx *_Nonnull ctx);
