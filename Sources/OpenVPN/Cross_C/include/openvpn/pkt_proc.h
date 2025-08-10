/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "crypto/endian.h"
#include "crypto/zeroing_data.h"

typedef enum {
    PktProcMethodNone,
    PktProcMethodXORMask,
    PktProcMethodXORPtrPos,
    PktProcMethodReverse,
    PktProcMethodXORObfuscate
} pkt_proc_method;

typedef struct {
    uint8_t *_Nonnull dst;
    size_t dst_offset;
    const uint8_t *_Nonnull src;
    size_t src_offset;
    size_t src_len;
    const uint8_t *_Nullable mask;
    size_t mask_len;
} pkt_proc_alg_ctx;

typedef void (*pkt_proc_algorithm)(const pkt_proc_alg_ctx *_Nonnull);

typedef struct {
    pp_zd *_Nullable mask;
    pkt_proc_algorithm _Nonnull recv;
    pkt_proc_algorithm _Nonnull send;
} pkt_proc_t;

pkt_proc_t *_Nonnull pkt_proc_create(pkt_proc_method method,
                                     const uint8_t *_Nullable mask,
                                     size_t mask_len);

void pkt_proc_free(pkt_proc_t *_Nonnull proc);

// MARK: - Raw

static inline
void pkt_proc_recv(const pkt_proc_t *_Nonnull proc,
                   uint8_t *_Nonnull dst,
                   const uint8_t *_Nonnull src,
                   size_t src_len) {

    const pkt_proc_alg_ctx ctx = {
        dst, 0,
        src, 0, src_len,
        proc->mask ? proc->mask->bytes : NULL,
        proc->mask ? proc->mask->length : 0
    };
    proc->recv(&ctx);
}

static inline
void pkt_proc_send(const pkt_proc_t *_Nonnull proc,
                   uint8_t *_Nonnull dst,
                   const uint8_t *_Nonnull src,
                   size_t src_len) {

    const pkt_proc_alg_ctx ctx = {
        dst, 0,
        src, 0, src_len,
        proc->mask ? proc->mask->bytes : NULL,
        proc->mask ? proc->mask->length : 0
    };
    proc->send(&ctx);
}

// MARK: - Streams (TCP)

#define pkt_proc_stream_header_len sizeof(uint16_t)

// loop until 0
// stream -> parse packet and return new offset
static inline
pp_zd *_Nullable pkt_proc_stream_recv(const void *_Nonnull vproc,
                                               const uint8_t *_Nonnull src,
                                               size_t src_len,
                                               size_t *_Nullable src_rcvd) {

    if (src_len < pkt_proc_stream_header_len) {
        return NULL;
    }

    // [length(2 bytes)][packet(length)]
    const size_t buf_len = pp_endian_ntohs(*(uint16_t *)src);
    const uint8_t *buf_payload = src + pkt_proc_stream_header_len;
    if (src_len < pkt_proc_stream_header_len + buf_len) {
        return NULL;
    }

    const pkt_proc_t *proc = vproc;
    pp_zd *dst = pp_zd_create(buf_len);
    const pkt_proc_alg_ctx ctx = {
        dst->bytes, 0,
        buf_payload, 0, buf_len,
        proc->mask ? proc->mask->bytes : NULL,
        proc->mask ? proc->mask->length : 0
    };
    proc->recv(&ctx);
    if (src_rcvd) {
        *src_rcvd = pkt_proc_stream_header_len + buf_len;
    }
    return dst;
}

static inline
size_t pkt_proc_stream_send_bufsize(const int num, const size_t len) {
    return len + num * pkt_proc_stream_header_len;
}

static inline
size_t pkt_proc_stream_send(const void *_Nonnull vproc,
                            pp_zd *_Nonnull dst,
                            size_t dst_offset,
                            const uint8_t *_Nonnull src,
                            size_t src_len) {

    const size_t buf_len = pkt_proc_stream_header_len + src_len;
    pp_assert(dst->length >= dst_offset + buf_len);

    uint8_t *ptr = dst->bytes + dst_offset;
    *(uint16_t *)ptr = pp_endian_htons(src_len);
    ptr += pkt_proc_stream_header_len;

    const pkt_proc_t *proc = vproc;
    const pkt_proc_alg_ctx ctx = {
        ptr, 0,
        src, 0, src_len,
        proc->mask ? proc->mask->bytes : NULL,
        proc->mask ? proc->mask->length : 0
    };
    proc->send(&ctx);
    return dst_offset + buf_len;
}
