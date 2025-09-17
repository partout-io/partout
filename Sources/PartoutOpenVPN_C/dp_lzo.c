/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "openvpn/dp_lzo.h"
#include "openvpn/dp_macros.h"

void openvpn_dp_lzo_assemble(openvpn_dp_framing_assemble_ctx *_Nonnull ctx) {
    size_t src_comp_len = 0;
    uint8_t *src_comp = pp_lzo_compress(ctx->lzo, &src_comp_len, ctx->src, ctx->src_len);
    if (src_comp) {
        ctx->dst[0] = OpenVPNDataPacketLZOCompress;
        *ctx->dst_len_offset = 1 - ((int)ctx->src_len - (int)src_comp_len);
        memcpy(ctx->dst + 1, src_comp, src_comp_len);
        pp_free(src_comp);
    } else {
        // Do not byte swap if LZO enabled
        ctx->dst[0] = OpenVPNDataPacketNoCompress;
        *ctx->dst_len_offset = 1;
        memcpy(ctx->dst + 1, ctx->src, ctx->src_len);
    }
}

bool openvpn_dp_lzo_parse(pp_lzo lzo,
                          openvpn_compression_framing comp_f,
                          uint8_t dst_header,
                          pp_zd *dst,
                          size_t dst_len,
                          bool *is_compressed) {
    if (lzo && comp_f != OpenVPNCompressionFramingDisabled) {
        if (dst_header == OpenVPNDataPacketLZOCompress) {
            size_t dst_comp_len = 0;
            unsigned char *dst_comp = pp_lzo_decompress(lzo,
                                                        &dst_comp_len,
                                                        dst->bytes,
                                                        dst_len); // Not dst->length, not resized yet
            if (!dst_comp) {
                OPENVPN_DP_LOG("openvpn_dp_mode_decrypt_and_parse: LZO decompression failed");
                return false;
            }
            pp_zd_resize(dst, dst_comp_len);
            memcpy(dst->bytes, dst_comp, dst_comp_len);
            pp_free(dst_comp);
            *is_compressed = true;
        }
    }
    return true;
}
