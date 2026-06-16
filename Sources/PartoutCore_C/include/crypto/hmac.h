/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>
#include "portable/zd.h"

#pragma clang assume_nonnull begin

typedef struct {
    uint8_t *dst;
    size_t dst_len;
    const char *digest_name;
    const uint8_t *secret;
    size_t secret_len;
    const uint8_t *data;
    size_t data_len;
} pp_hmac_ctx;

pp_zd *pp_hmac_create(void);
size_t pp_hmac_do(pp_hmac_ctx *ctx);

#pragma clang assume_nonnull end
