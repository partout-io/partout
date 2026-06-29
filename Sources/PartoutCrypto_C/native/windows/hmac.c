/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "../mbed/hmac_mbed.h"

size_t pp_hmac_do(pp_hmac_ctx *ctx) {
    return pp_mbed_hmac_do(ctx);
}
