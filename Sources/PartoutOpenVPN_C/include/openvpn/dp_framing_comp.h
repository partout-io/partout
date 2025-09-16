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
void openvpn_dp_framing_assemble_disabled(openvpn_dp_framing_assemble_ctx *_Nonnull ctx) {
    memcpy(ctx->dst, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        openvpn_mss_fix(ctx->dst, ctx->src_len, ctx->mss_val);
    }
    *ctx->dst_len_offset = 0;
}

static
bool openvpn_dp_framing_parse_disabled(openvpn_dp_framing_parse_ctx *_Nonnull ctx) {
    *ctx->dst_payload_offset = 0;
    *ctx->dst_header = 0x00;
    *ctx->dst_header_len = 0;
    return true;
}

// MARK: -

static
bool openvpn_dp_framing_parse_v1(openvpn_dp_framing_parse_ctx *_Nonnull ctx) {
    *ctx->dst_header = ctx->dst_payload[0];
    *ctx->dst_payload_offset = 0;
    *ctx->dst_header_len = 0;

    switch (*ctx->dst_header) {
        case OpenVPNDataPacketNoCompress:
            *ctx->dst_payload_offset = 1;
            *ctx->dst_header_len = 1;
            break;

        case OpenVPNDataPacketNoCompressSwap:
            ctx->dst_payload[0] = ctx->src[ctx->src_len - 1];
            *ctx->dst_payload_offset = 0;
            *ctx->dst_header_len = 1;
            break;

        case OpenVPNDataPacketLZOCompress:
#ifdef OPENVPN_DEPRECATED_LZO
            // FIXME: ###, decompress LZO packet
            break;
#else
            if (ctx->error) {
                ctx->error->dp_code = OpenVPNDataPathErrorCompression;
                ctx->error->crypto_code = PPCryptoErrorNone;
            }
            return false;
#endif

        default:
            break;
    }
    return true;
}

static
bool openvpn_dp_framing_parse_v2(openvpn_dp_framing_parse_ctx *_Nonnull ctx) {
    *ctx->dst_header = ctx->dst_payload[0];
    *ctx->dst_payload_offset = 0;
    *ctx->dst_header_len = 0;

    switch (*ctx->dst_header) {
        case OpenVPNDataPacketV2Indicator:
            if (ctx->dst_payload[1] != OpenVPNDataPacketV2Uncompressed) {
                if (ctx->error) {
                    ctx->error->dp_code = OpenVPNDataPathErrorCompression;
                    ctx->error->crypto_code = PPCryptoErrorNone;
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
void openvpn_dp_framing_assemble_lzo(openvpn_dp_framing_assemble_ctx *_Nonnull ctx) {
    ctx->dst[0] = OpenVPNDataPacketNoCompress;
    *ctx->dst_len_offset = 1;
    memcpy(ctx->dst + 1, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        openvpn_mss_fix(ctx->dst + 1, ctx->src_len, ctx->mss_val);
    }
}

static
bool openvpn_dp_framing_parse_lzo(openvpn_dp_framing_parse_ctx *_Nonnull ctx) {
    return openvpn_dp_framing_parse_v1(ctx);
}

static
void openvpn_dp_framing_assemble_compress(openvpn_dp_framing_assemble_ctx *_Nonnull ctx) {
    *ctx->dst_len_offset = 1;
    memcpy(ctx->dst, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        openvpn_mss_fix(ctx->dst, ctx->src_len, ctx->mss_val);
    }
    // swap (compression disabled)
    ctx->dst[ctx->src_len] = ctx->dst[0];
    ctx->dst[0] = OpenVPNDataPacketNoCompressSwap;
}

static
bool openvpn_dp_framing_parse_compress(openvpn_dp_framing_parse_ctx *_Nonnull ctx) {
    return openvpn_dp_framing_parse_v1(ctx);
}

static
void openvpn_dp_framing_assemble_compress_v2(openvpn_dp_framing_assemble_ctx *_Nonnull ctx) {
    // assume no compression (v2 algorithms unsupported)

    // prepend headers only in case of byte ambiguity
    const uint8_t first = *(uint8_t *)ctx->src;
    if (first == OpenVPNDataPacketV2Indicator) {
        *ctx->dst_len_offset = 2;
        ctx->dst[0] = OpenVPNDataPacketV2Indicator;
        ctx->dst[1] = OpenVPNDataPacketV2Uncompressed;
    } else {
        *ctx->dst_len_offset = 0;
    }
    memcpy(ctx->dst + *ctx->dst_len_offset, ctx->src, ctx->src_len);
    if (ctx->mss_val) {
        openvpn_mss_fix(ctx->dst + *ctx->dst_len_offset, ctx->src_len, ctx->mss_val);
    }
}

static
bool openvpn_dp_framing_parse_compress_v2(openvpn_dp_framing_parse_ctx *_Nonnull ctx) {
    return openvpn_dp_framing_parse_v2(ctx);
}
