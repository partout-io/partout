/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
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
void alg_plain(const openvpn_pkt_proc_alg_ctx *ctx) {
    pp_assert(ctx);
    memcpy(ctx->dst + ctx->dst_offset, ctx->src + ctx->src_offset, ctx->src_len);
}

static
void alg_xor_mask(const openvpn_pkt_proc_alg_ctx *ctx) {
    pp_assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    openvpn_obf_xor_mask(ctx->dst + ctx->dst_offset, ctx->src_len, ctx->mask, ctx->mask_len);
}

static
void alg_xor_ptrpos(const openvpn_pkt_proc_alg_ctx *ctx) {
    alg_plain(ctx);
    openvpn_obf_xor_ptrpos(ctx->dst + ctx->dst_offset, ctx->src_len);
}

static
void alg_reverse(const openvpn_pkt_proc_alg_ctx *ctx) {
    alg_plain(ctx);
    openvpn_obf_reverse(ctx->dst + ctx->dst_offset, ctx->src_len);
}

static
void alg_xor_obfuscate_in(const openvpn_pkt_proc_alg_ctx *ctx) {
    pp_assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    openvpn_obf_xor_obfuscate(ctx->dst + ctx->dst_offset,
                      ctx->src_len,
                      ctx->mask, ctx->mask_len,
                      false);
}

static
void alg_xor_obfuscate_out(const openvpn_pkt_proc_alg_ctx *ctx) {
    pp_assert(ctx->mask && ctx->mask_len);
    alg_plain(ctx);
    openvpn_obf_xor_obfuscate(ctx->dst + ctx->dst_offset,
                      ctx->src_len,
                      ctx->mask, ctx->mask_len,
                      true);
}

// MARK: - Obfuscator

openvpn_pkt_proc *openvpn_pkt_proc_create(openvpn_pkt_proc_method method, const uint8_t *mask, size_t mask_len) {
    openvpn_pkt_proc *proc = pp_alloc(sizeof(openvpn_pkt_proc));
    proc->mask = NULL;
    switch (method) {
        case OpenVPNPktProcMethodNone:
            proc->recv = alg_plain;
            proc->send = alg_plain;
            break;
        case OpenVPNPktProcMethodXORMask:
            proc->recv = alg_xor_mask;
            proc->send = alg_xor_mask;
            proc->mask = pp_zd_create_from_data(mask, mask_len);
            break;
        case OpenVPNPktProcMethodXORPtrPos:
            proc->recv = alg_xor_ptrpos;
            proc->send = alg_xor_ptrpos;
            break;
        case OpenVPNPktProcMethodReverse:
            proc->recv = alg_reverse;
            proc->send = alg_reverse;
            break;
        case OpenVPNPktProcMethodXORObfuscate:
            proc->recv = alg_xor_obfuscate_in;
            proc->send = alg_xor_obfuscate_out;
            proc->mask = pp_zd_create_from_data(mask, mask_len);
            break;
    }
    return proc;
}

void openvpn_pkt_proc_free(openvpn_pkt_proc *proc) {
    if (proc->mask) {
        pp_zd_free(proc->mask);
    }
    pp_free(proc);
}

// MARK: - Streams (TCP)

pp_zd *_Nullable openvpn_pkt_proc_stream_recv(const void *vproc,
                                              const uint8_t *src,
                                              size_t src_len,
                                              size_t *_Nullable src_rcvd) {
    if (src_len < OpenVPNPktProcStreamHeaderLength) {
        return NULL;
    }

    // [length(2 bytes)][packet(length)]
    const size_t buf_len = pp_endian_ntohs(*(uint16_t *)src);
    const uint8_t *buf_payload = src + OpenVPNPktProcStreamHeaderLength;
    if (src_len < OpenVPNPktProcStreamHeaderLength + buf_len) {
        return NULL;
    }

    const openvpn_pkt_proc *proc = vproc;
    pp_zd *dst = pp_zd_create(buf_len);
    openvpn_pkt_proc_recv(proc, dst->bytes, buf_payload, buf_len);
    if (src_rcvd) {
        *src_rcvd = OpenVPNPktProcStreamHeaderLength + buf_len;
    }
    return dst;
}

size_t openvpn_pkt_proc_stream_send(const void *vproc,
                                    pp_zd *dst,
                                    size_t dst_offset,
                                    const uint8_t *src,
                                    size_t src_len) {
    const size_t buf_len = OpenVPNPktProcStreamHeaderLength + src_len;
    pp_assert(dst->length >= dst_offset + buf_len);

    uint8_t *ptr = dst->bytes + dst_offset;
    *(uint16_t *)ptr = pp_endian_htons(src_len);
    ptr += OpenVPNPktProcStreamHeaderLength;

    const openvpn_pkt_proc *proc = vproc;
    openvpn_pkt_proc_send(proc, ptr, src, src_len);
    return dst_offset + buf_len;
}
