/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/endian.h"
#include "openvpn/dp_macros.h"
#include "openvpn/dp_mode_ad.h"
#include "openvpn/packet.h"

static
size_t dp_assemble(void *vmode) {
    OPENVPN_DP_LOG("openvpn_dp_mode_ad_assemble");
    const openvpn_dp_mode *mode = vmode;
    const openvpn_dp_mode_assemble_ctx *ctx = &mode->assemble_ctx;

    const size_t dst_capacity = openvpn_dp_mode_assemble_capacity(mode, ctx->src_len);
    pp_assert(ctx->dst->length >= dst_capacity);

    uint8_t *dst = ctx->dst->bytes;
    size_t dst_len = ctx->src_len;
    if (!mode->enc.framing_assemble) {
        memcpy(ctx->dst, ctx->src, ctx->src_len);
    } else {
        int packet_len_offset;
        openvpn_dp_framing_assemble_ctx assemble;
        assemble.dst = dst;
        assemble.dst_len_offset = &packet_len_offset;
        assemble.src = ctx->src;
        assemble.src_len = ctx->src_len;
        assemble.mss_val = mode->opt.mss_val;
        assemble.lzo = ctx->lzo;
        mode->enc.framing_assemble(&assemble);
        dst_len += packet_len_offset;
    }
    return dst_len;
}

static
size_t dp_encrypt(void *vmode) {
    OPENVPN_DP_LOG("openvpn_dp_mode_ad_encrypt");
    const openvpn_dp_mode *mode = vmode;
    const openvpn_dp_mode_encrypt_ctx *ctx = &mode->enc_ctx;

    pp_assert(mode->enc.raw_encrypt);
    OPENVPN_DP_ENCRYPT_BEGIN(mode->opt.peer_id)

    const size_t dst_capacity = openvpn_dp_mode_encrypt_capacity(mode, ctx->src_len);
    pp_assert(ctx->dst->length >= dst_capacity);
    uint8_t *dst = ctx->dst->bytes;

    *(uint32_t *)(dst + dst_header_len) = pp_endian_htonl(ctx->packet_id);

    pp_crypto_flags flags = { 0 };
    flags.iv = dst + dst_header_len;
    flags.iv_len = OpenVPNPacketIdLength;
    if (has_peer_id) {
        openvpn_packet_header_v2_set(dst, ctx->key, mode->opt.peer_id);
        flags.ad = dst;
        flags.ad_len = dst_header_len + OpenVPNPacketIdLength;
    }
    else {
        openvpn_packet_header_set(dst, OpenVPNPacketCodeDataV1, ctx->key, NULL);
        flags.ad = dst + dst_header_len;
        flags.ad_len = OpenVPNPacketIdLength;
    }

    // skip header and packet id
    pp_crypto_error_code enc_error;
    const size_t dst_packet_len = mode->enc.raw_encrypt(mode->crypto,
                                                        dst + dst_header_len + OpenVPNPacketIdLength,
                                                        ctx->dst->length - (dst_header_len + OpenVPNPacketIdLength),
                                                        ctx->src,
                                                        ctx->src_len,
                                                        &flags,
                                                        &enc_error);

    pp_assert(dst_packet_len <= dst_capacity);//, "Did not allocate enough bytes for payload");

    if (!dst_packet_len) {
        if (ctx->error) {
            ctx->error->dp_code = OpenVPNDataPathErrorCrypto;
            ctx->error->crypto_code = enc_error;
        }
        return 0;
    }
    return dst_header_len + OpenVPNPacketIdLength + dst_packet_len;
}

static
size_t dp_decrypt(void *vmode) {
    OPENVPN_DP_LOG("openvpn_dp_mode_ad_decrypt");
    const openvpn_dp_mode *mode = vmode;
    const openvpn_dp_mode_decrypt_ctx *ctx = &mode->dec_ctx;

    pp_assert(mode->dec.raw_decrypt);
    pp_assert(ctx->src_len > 0);//, @"Decrypting an empty packet, how did it get this far?");
    pp_assert(ctx->dst->length >= ctx->src_len);
    uint8_t *dst = ctx->dst->bytes;

    OPENVPN_DP_DECRYPT_BEGIN(ctx)
    if (ctx->src_len < src_header_len + OpenVPNPacketIdLength) {
        return 0;
    }

    pp_crypto_flags flags = { 0 };
    flags.iv = ctx->src + src_header_len;
    flags.iv_len = OpenVPNPacketIdLength;
    if (has_peer_id) {
        if (peer_id != mode->opt.peer_id) {
            if (ctx->error) {
                ctx->error->dp_code = OpenVPNDataPathErrorPeerIdMismatch;
                ctx->error->crypto_code = PPCryptoErrorNone;
            }
            return 0;
        }
        flags.ad = ctx->src;
        flags.ad_len = src_header_len + OpenVPNPacketIdLength;
    }
    else {
        flags.ad = ctx->src + src_header_len;
        flags.ad_len = OpenVPNPacketIdLength;
    }

    // skip header + packet id
    pp_crypto_error_code dec_error;
    const size_t dst_len = mode->dec.raw_decrypt(mode->crypto,
                                                 dst,
                                                 ctx->dst->length,
                                                 ctx->src + src_header_len + OpenVPNPacketIdLength,
                                                 (int)(ctx->src_len - (src_header_len + OpenVPNPacketIdLength)),
                                                 &flags,
                                                 &dec_error);
    if (!dst_len) {
        if (ctx->error) {
            ctx->error->dp_code = OpenVPNDataPathErrorCrypto;
            ctx->error->crypto_code = dec_error;
        }
        return 0;
    }
    *ctx->dst_packet_id = pp_endian_ntohl(*(const uint32_t *)(flags.iv));
    return dst_len;
}

static
size_t dp_parse(void *vmode) {
    OPENVPN_DP_LOG("openvpn_dp_mode_ad_parse");
    const openvpn_dp_mode *mode = vmode;
    const openvpn_dp_mode_parse_ctx *ctx = &mode->parse_ctx;

    pp_assert(ctx->dst->length >= ctx->src_len);

    uint8_t *payload = ctx->src;
    size_t dst_len = ctx->src_len;// - (int)(payload - ctx->src);
    if (!mode->dec.framing_parse) {
        *ctx->dst_header = 0x00;
        memcpy(ctx->dst->bytes, payload, dst_len);
        return dst_len;
    }

    size_t payload_offset;
    size_t payload_header_len;
    openvpn_dp_framing_parse_ctx parse;
    parse.dst_payload = payload;
    parse.dst_payload_offset = &payload_offset;
    parse.dst_header = ctx->dst_header;
    parse.dst_header_len = &payload_header_len;
    parse.src = ctx->src;
    parse.src_len = ctx->src_len;
    parse.lzo = ctx->lzo;
    parse.error = ctx->error;
    if (!mode->dec.framing_parse(&parse)) {
        return 0;
    }
    dst_len -= payload_header_len;
    memcpy(ctx->dst->bytes, payload + payload_offset, dst_len);
    return dst_len;
}

// MARK: -

openvpn_dp_mode *openvpn_dp_mode_ad_create(pp_crypto_ctx crypto,
                                           pp_crypto_free_fn pp_crypto_free,
                                           openvpn_compression_framing comp_f,
                                           bool with_lzo) {

    OPENVPN_DP_LOG("openvpn_dp_mode_ad_create");

    const openvpn_dp_framing *frm = openvpn_dp_framing_of(comp_f);
    const openvpn_dp_mode_encrypter enc = {
        frm->assemble,
        dp_assemble,
        NULL,
        dp_encrypt
    };
    const openvpn_dp_mode_decrypter dec = {
        frm->parse,
        dp_parse,
        NULL,
        dp_decrypt
    };
    const openvpn_dp_mode_options opt = {
        comp_f,
        OpenVPNPacketPeerIdDisabled,
        0,
        with_lzo
    };
    return openvpn_dp_mode_create_opt(crypto, pp_crypto_free, &enc, &dec, &opt);
}
