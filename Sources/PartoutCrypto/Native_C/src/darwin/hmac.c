/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/hmac.h"
#include "crypto_darwin.h"

size_t pp_hmac_do(pp_hmac_ctx *ctx) {
    pp_assert(ctx);
    pp_assert(ctx->dst_len >= PP_CC_HMAC_MAX_LENGTH);

    pp_cc_digest digest;
    if (!pp_cc_digest_by_name(ctx->digest_name, &digest)) {
        return 0;
    }

    CCHmac(digest.algorithm,
           ctx->secret, ctx->secret_len,
           ctx->data, ctx->data_len,
           ctx->dst);
    return digest.length;
}
