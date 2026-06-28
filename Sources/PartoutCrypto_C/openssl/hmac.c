/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/hmac.h>
#include "crypto/hmac.h"
#include "portable/common.h"

#define HMACMaxLength    (size_t)128

size_t pp_hmac_do(pp_hmac_ctx *ctx) {
    pp_assert(ctx->dst_len >= HMACMaxLength);

    const EVP_MD *md = EVP_get_digestbyname(ctx->digest_name);
    if (!md) {
        return 0;
    }
    unsigned int dst_len = 0;
    const bool success = HMAC(md, ctx->secret, (int)ctx->secret_len,
                              ctx->data, ctx->data_len,
                              ctx->dst, &dst_len) != NULL;
    if (!success) {
        return 0;
    }
    return dst_len;
}
