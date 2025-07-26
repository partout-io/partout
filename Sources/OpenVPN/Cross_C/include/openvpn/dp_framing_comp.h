/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <string.h>
#include "openvpn/dp_framing.h"
#include "openvpn/mss_fix.h"
#include "openvpn/packet.h"

static
void dp_framing_assemble_disabled(dp_framing_assemble_ctx *_Nonnull ctx) {
    memcpy(ctx->dst, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        mss_fix(ctx->dst, ctx->src_len, ctx->mss_val);
    }
    *ctx->dst_len_offset = 0;
}

static
bool dp_framing_parse_disabled(dp_framing_parse_ctx *_Nonnull ctx) {
    *ctx->dst_payload_offset = 0;
    *ctx->dst_header = 0x00;
    *ctx->dst_header_len = 0;
    return true;
}

// MARK: -

static
bool dp_framing_parse_v1(dp_framing_parse_ctx *_Nonnull ctx) {
    *ctx->dst_header = ctx->dst_payload[0];
    *ctx->dst_payload_offset = 0;
    *ctx->dst_header_len = 0;

    switch (*ctx->dst_header) {
        case DataPacketNoCompress:
            *ctx->dst_payload_offset = 1;
            *ctx->dst_header_len = 1;
            break;

        case DataPacketNoCompressSwap:
            ctx->dst_payload[0] = ctx->src[ctx->src_len - 1];
            *ctx->dst_payload_offset = 0;
            *ctx->dst_header_len = 1;
            break;

        case DataPacketLZOCompress:
            if (ctx->error) {
                ctx->error->dp_code = DataPathErrorCompression;
                ctx->error->crypto_code = CryptoErrorNone;
            }
            return false;

        default:
            break;
    }
    return true;
}

static
bool dp_framing_parse_v2(dp_framing_parse_ctx *_Nonnull ctx) {
    *ctx->dst_header = ctx->dst_payload[0];
    *ctx->dst_payload_offset = 0;
    *ctx->dst_header_len = 0;

    switch (*ctx->dst_header) {
        case DataPacketV2Indicator:
            if (ctx->dst_payload[1] != DataPacketV2Uncompressed) {
                if (ctx->error) {
                    ctx->error->dp_code = DataPathErrorCompression;
                    ctx->error->crypto_code = CryptoErrorNone;
                }
                return false;
            }
            *ctx->dst_payload_offset = 2;
            *ctx->dst_header_len = 2;
            break;

        default:
            break;
    }
    return true;
}

static
void dp_framing_assemble_lzo(dp_framing_assemble_ctx *_Nonnull ctx) {
    ctx->dst[0] = DataPacketNoCompress;
    *ctx->dst_len_offset = 1;
    memcpy(ctx->dst + 1, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        mss_fix(ctx->dst + 1, ctx->src_len, ctx->mss_val);
    }
}

static
bool dp_framing_parse_lzo(dp_framing_parse_ctx *_Nonnull ctx) {
    return dp_framing_parse_v1(ctx);
}

static
void dp_framing_assemble_compress(dp_framing_assemble_ctx *_Nonnull ctx) {
    *ctx->dst_len_offset = 1;
    memcpy(ctx->dst, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        mss_fix(ctx->dst, ctx->src_len, ctx->mss_val);
    }
    // swap (compression disabled)
    ctx->dst[ctx->src_len] = ctx->dst[0];
    ctx->dst[0] = DataPacketNoCompressSwap;
}

static
bool dp_framing_parse_compress(dp_framing_parse_ctx *_Nonnull ctx) {
    return dp_framing_parse_v1(ctx);
}

static
void dp_framing_assemble_compress_v2(dp_framing_assemble_ctx *_Nonnull ctx) {
    // assume no compression (v2 algorithms unsupported)

    // prepend headers only in case of byte ambiguity
    const uint8_t first = *(uint8_t *)ctx->src;
    if (first == DataPacketV2Indicator) {
        *ctx->dst_len_offset = 2;
        ctx->dst[0] = DataPacketV2Indicator;
        ctx->dst[1] = DataPacketV2Uncompressed;
    } else {
        *ctx->dst_len_offset = 0;
    }
    memcpy(ctx->dst + *ctx->dst_len_offset, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        mss_fix(ctx->dst + *ctx->dst_len_offset, ctx->src_len, ctx->mss_val);
    }
}

static
bool dp_framing_parse_compress_v2(dp_framing_parse_ctx *_Nonnull ctx) {
    return dp_framing_parse_v2(ctx);
}
