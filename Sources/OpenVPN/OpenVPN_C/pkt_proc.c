//
//  pkt_proc.c
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

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include "crypto/allocation.h"
#include "openvpn/obf.h"
#include "openvpn/pkt_proc.h"

// MARK: - Pointers

static inline
void alg_plain(const pkt_proc_alg_ctx *ctx) {
    assert(ctx);
    memcpy(ctx->dst + ctx->dst_offset, ctx->src + ctx->src_offset, ctx->src_len);
}

static
void alg_xor_mask(const pkt_proc_alg_ctx *ctx) {
    assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    obf_xor_mask(ctx->dst + ctx->dst_offset, ctx->src_len, ctx->mask, ctx->mask_len);
}

static
void alg_xor_ptrpos(const pkt_proc_alg_ctx *ctx) {
    alg_plain(ctx);
    obf_xor_ptrpos(ctx->dst + ctx->dst_offset, ctx->src_len);
}

static
void alg_reverse(const pkt_proc_alg_ctx *ctx) {
    alg_plain(ctx);
    obf_reverse(ctx->dst + ctx->dst_offset, ctx->src_len);
}

static
void alg_xor_obfuscate_in(const pkt_proc_alg_ctx *ctx) {
    assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    obf_xor_obfuscate(ctx->dst + ctx->dst_offset,
                      ctx->src_len,
                      ctx->mask, ctx->mask_len,
                      false);
}

static
void alg_xor_obfuscate_out(const pkt_proc_alg_ctx *ctx) {
    assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    obf_xor_obfuscate(ctx->dst + ctx->dst_offset,
                      ctx->src_len,
                      ctx->mask, ctx->mask_len,
                      true);
}

// MARK: - Obfuscator

pkt_proc_t *pkt_proc_create(pkt_proc_method method, const uint8_t *mask, size_t mask_len) {
    pkt_proc_t *proc = pp_alloc_crypto(sizeof(pkt_proc_t));
    proc->mask = NULL;
    switch (method) {
        case PktProcMethodNone:
            proc->recv = alg_plain;
            proc->send = alg_plain;
            break;
        case PktProcMethodXORMask:
            proc->recv = alg_xor_mask;
            proc->send = alg_xor_mask;
            proc->mask = zd_create_from_data(mask, mask_len);
            break;
        case PktProcMethodXORPtrPos:
            proc->recv = alg_xor_ptrpos;
            proc->send = alg_xor_ptrpos;
            break;
        case PktProcMethodReverse:
            proc->recv = alg_reverse;
            proc->send = alg_reverse;
            break;
        case PktProcMethodXORObfuscate:
            proc->recv = alg_xor_obfuscate_in;
            proc->send = alg_xor_obfuscate_out;
            proc->mask = zd_create_from_data(mask, mask_len);
            break;
    }
    return proc;
}

void pkt_proc_free(pkt_proc_t *proc) {
    if (proc->mask) {
        zd_free(proc->mask);
    }
    free(proc);
}
