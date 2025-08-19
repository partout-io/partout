/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>
#include "portable/zd.h"

typedef struct {
    pp_zd *_Nonnull dst;
    const char *_Nonnull digest_name;
    const pp_zd *_Nonnull secret;
    const pp_zd *_Nonnull data;
} pp_hmac_ctx;

pp_zd *_Nonnull pp_hmac_create();
size_t pp_hmac_do(pp_hmac_ctx *_Nonnull ctx);
