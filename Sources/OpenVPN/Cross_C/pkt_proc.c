/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdbool.h>
#include <stddef.h>
#include "portable/common.h"
#include "openvpn/obf.h"
#include "openvpn/pkt_proc.h"

// MARK: - Pointers

static inline
void alg_plain(const pkt_proc_alg_ctx *ctx) {
    pp_assert(ctx);
    memcpy(ctx->dst + ctx->dst_offset, ctx->src + ctx->src_offset, ctx->src_len);
}

static
void alg_xor_mask(const pkt_proc_alg_ctx *ctx) {
    pp_assert(ctx->mask && ctx->mask_len);
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
    pp_assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    obf_xor_obfuscate(ctx->dst + ctx->dst_offset,
                      ctx->src_len,
                      ctx->mask, ctx->mask_len,
                      false);
}

static
void alg_xor_obfuscate_out(const pkt_proc_alg_ctx *ctx) {
    pp_assert(ctx->mask && ctx->mask_len);
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
            proc->mask = pp_zd_create_from_data(mask, mask_len);
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
            proc->mask = pp_zd_create_from_data(mask, mask_len);
            break;
    }
    return proc;
}

void pkt_proc_free(pkt_proc_t *proc) {
    if (proc->mask) {
        pp_zd_free(proc->mask);
    }
    free(proc);
}
