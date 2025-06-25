//
//  obf.c
//  Partout
//
//  Created by Davide De Rosa on 6/25/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

#include "crypto/endian.h"
#include "openvpn/obf.h"

// WARNING: assume dst to be able to hold src_len

// TODO: ##, make more efficient by XOR-ing 4-8 bytes per loop

static inline
void obf_xor_mask(uint8_t *_Nonnull dst,
                  size_t dst_len,
                  const uint8_t *_Nonnull mask,
                  size_t mask_len) {

    assert(mask && mask_len > 0);
    if (mask_len == 0) {
        return;
    }
    for (size_t i = 0; i < dst_len; ++i) {
        dst[i] ^= mask[i % mask_len];
    }
}

static inline
void obf_xor_ptrpos(uint8_t *_Nonnull dst, size_t dst_len) {

    for (size_t i = 0; i < dst_len; ++i) {
        dst[i] ^= ((i + 1) & 0xff);
    }
}

// first byte as-is, [1..n-1] reversed
static inline
void obf_reverse(uint8_t *_Nonnull dst, size_t dst_len) {

    if (dst_len <= 2) {
        return;
    }
    size_t start = 1;
    size_t end = dst_len - 1;
    uint8_t temp = 0;
    while (start < end) {
        temp = dst[start];
        dst[start] = dst[end];
        dst[end] = temp;
        start++;
        end--;
    }
}

static inline
void obf_xor_obfuscate(uint8_t *_Nonnull dst,
                       size_t dst_len,
                       const uint8_t *_Nonnull mask,
                       size_t mask_len,
                       bool outbound)
{
    if (outbound) {
        obf_xor_ptrpos(dst, dst_len);
        obf_reverse(dst, dst_len);
        obf_xor_ptrpos(dst, dst_len);
        obf_xor_mask(dst, dst_len, mask, mask_len);
    } else {
        obf_xor_mask(dst, dst_len, mask, mask_len);
        obf_xor_ptrpos(dst, dst_len);
        obf_reverse(dst, dst_len);
        obf_xor_ptrpos(dst, dst_len);
    }
}

// MARK: - Pointers

static
void alg_plain(const obf_alg_ctx *ctx) {
    assert(ctx);
    memcpy(ctx->dst + ctx->dst_offset, ctx->src + ctx->src_offset, ctx->src_len);
}

static
void alg_xor_mask(const obf_alg_ctx *ctx) {
    assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    obf_xor_mask(ctx->dst + ctx->dst_offset, ctx->src_len, ctx->mask, ctx->mask_len);
}

static
void alg_xor_ptrpos(const obf_alg_ctx *ctx) {
    alg_plain(ctx);
    obf_xor_ptrpos(ctx->dst + ctx->dst_offset, ctx->src_len);
}

static
void alg_reverse(const obf_alg_ctx *ctx) {
    alg_plain(ctx);
    obf_reverse(ctx->dst + ctx->dst_offset, ctx->src_len);
}

static
void alg_xor_obfuscate_in(const obf_alg_ctx *ctx) {
    assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    obf_xor_obfuscate(ctx->dst + ctx->dst_offset,
                      ctx->src_len,
                      ctx->mask, ctx->mask_len,
                      false);
}

static
void alg_xor_obfuscate_out(const obf_alg_ctx *ctx) {
    assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    obf_xor_obfuscate(ctx->dst + ctx->dst_offset,
                      ctx->src_len,
                      ctx->mask, ctx->mask_len,
                      true);
}

// MARK: -

obf_t *obf_create(obf_method method, const uint8_t *mask, size_t mask_len) {
    obf_t *obf = pp_alloc_crypto(sizeof(obf_t));
    obf->mask = NULL;
    switch (method) {
        case OBFMethodNone:
            obf->recv = alg_plain;
            obf->send = alg_plain;
            break;
        case OBFMethodXORMask:
            obf->recv = alg_xor_mask;
            obf->send = alg_xor_mask;
            obf->mask = zd_create_copy(mask, mask_len);
            break;
        case OBFMethodXORPtrPos:
            obf->recv = alg_xor_ptrpos;
            obf->send = alg_xor_ptrpos;
            break;
        case OBFMethodReverse:
            obf->recv = alg_reverse;
            obf->send = alg_reverse;
            break;
        case OBFMethodXORObfuscate:
            obf->recv = alg_xor_obfuscate_in;
            obf->send = alg_xor_obfuscate_out;
            obf->mask = zd_create_copy(mask, mask_len);
            break;
    }
    return obf;
}

void obf_free(obf_t *obf) {
    if (obf->mask) {
        zd_free(obf->mask);
    }
    free(obf);
}
