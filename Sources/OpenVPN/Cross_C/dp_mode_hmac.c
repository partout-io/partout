/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdint.h>
#include "portable/endian.h"
#include "openvpn/dp_macros.h"
#include "openvpn/dp_mode_hmac.h"
#include "openvpn/packet.h"

static
size_t dp_assemble(void *vmode) {
    DP_LOG("dp_mode_hmac_assemble");
    const dp_mode_t *mode = vmode;
    const dp_mode_assemble_ctx *ctx = &mode->assemble_ctx;

    const size_t dst_capacity = dp_mode_assemble_capacity(mode, ctx->src_len);
    pp_assert(ctx->dst->length >= dst_capacity);

    uint8_t *dst = ctx->dst->bytes;
    *(uint32_t *)dst = pp_endian_htonl(ctx->packet_id);
    dst += sizeof(uint32_t);
    size_t dst_len = (size_t)(dst - ctx->dst->bytes + ctx->src_len);
    if (!mode->enc.framing_assemble) {
        memcpy(dst, ctx->src, ctx->src_len);
    } else {
        size_t packet_len_offset;
        dp_framing_assemble_ctx assemble;
        assemble.dst = dst;
        assemble.dst_len_offset = &packet_len_offset;
        assemble.src = ctx->src;
        assemble.src_len = ctx->src_len;
        assemble.mss_val = mode->opt.mss_val;
        mode->enc.framing_assemble(&assemble);
        dst_len += packet_len_offset;
    }
    return dst_len;
}

static
size_t dp_encrypt(void *vmode) {
    DP_LOG("dp_mode_hmac_encrypt");
    const dp_mode_t *mode = vmode;
    const dp_mode_encrypt_ctx *ctx = &mode->enc_ctx;

    pp_assert(mode->enc.raw_encrypt);
    DP_ENCRYPT_BEGIN(mode->opt.peer_id)

    const size_t dst_capacity = dp_mode_encrypt_capacity(mode, ctx->src_len);
    pp_assert(ctx->dst->length >= dst_capacity);
    uint8_t *dst = ctx->dst->bytes;

    // skip header bytes
    pp_crypto_error_code enc_error;
    const size_t dst_packet_len = mode->enc.raw_encrypt(mode->crypto,
                                                        dst + dst_header_len,
                                                        ctx->dst->length - dst_header_len,
                                                        ctx->src,
                                                        ctx->src_len,
                                                        NULL,
                                                        &enc_error);

    pp_assert(dst_packet_len <= dst_capacity);//, @"Did not allocate enough bytes for payload");

    if (!dst_packet_len) {
        if (ctx->error) {
            ctx->error->dp_code = DataPathErrorCrypto;
            ctx->error->pp_crypto_code = enc_error;
        }
        return 0;
    }
    if (has_peer_id) {
        packet_header_v2_set(dst, ctx->key, mode->opt.peer_id);
    } else {
        packet_header_set(dst, PacketCodeDataV1, ctx->key, NULL);
    }
    return dst_header_len + dst_packet_len;
}

static
size_t dp_decrypt(void *vmode) {
    DP_LOG("dp_mode_hmac_decrypt");
    const dp_mode_t *mode = vmode;
    const dp_mode_decrypt_ctx *ctx = &mode->dec_ctx;

    pp_assert(mode->dec.raw_decrypt);
    pp_assert(ctx->src_len > 0);//, @"Decrypting an empty packet, how did it get this far?");
    pp_assert(ctx->dst->length >= ctx->src_len);
    uint8_t *dst = ctx->dst->bytes;

    DP_DECRYPT_BEGIN(ctx)
    const pp_crypto_ctx crypto = (const pp_crypto_ctx)mode->crypto;
    if (ctx->src_len < src_header_len + crypto->base.meta.digest_len + crypto->base.meta.cipher_iv_len) {
        return 0;
    }

    // skip header = (code, key)
    pp_crypto_error_code dec_error;
    const size_t dst_len = mode->dec.raw_decrypt(mode->crypto,
                                                 dst,
                                                 ctx->dst->length,
                                                 ctx->src + src_header_len,
                                                 (int)(ctx->src_len - src_header_len),
                                                 NULL,
                                                 &dec_error);
    if (!dst_len) {
        if (ctx->error) {
            ctx->error->dp_code = DataPathErrorCrypto;
            ctx->error->pp_crypto_code = dec_error;
        }
        return 0;
    }
    if (has_peer_id) {
        if (peer_id != mode->opt.peer_id) {
            if (ctx->error) {
                ctx->error->dp_code = DataPathErrorPeerIdMismatch;
                ctx->error->pp_crypto_code = PPCryptoErrorNone;
            }
            return 0;
        }
    }
    *ctx->dst_packet_id = pp_endian_ntohl(*(uint32_t *)ctx->dst->bytes);
    return dst_len;
}

static
size_t dp_parse(void *vmode) {
    DP_LOG("dp_mode_hmac_parse");
    const dp_mode_t *mode = vmode;
    const dp_mode_parse_ctx *ctx = &mode->parse_ctx;

    pp_assert(ctx->dst->length >= ctx->src_len);

    uint8_t *payload = ctx->src;
    payload += sizeof(uint32_t); // packet id
    size_t dst_len = ctx->src_len - (int)(payload - ctx->src);
    if (!mode->dec.framing_parse) {
        *ctx->dst_header = 0x00;
        memcpy(ctx->dst->bytes, payload, dst_len);
        return dst_len;
    }

    size_t payload_offset;
    size_t payload_header_len;
    dp_framing_parse_ctx parse;
    parse.dst_payload = payload;
    parse.dst_payload_offset = &payload_offset;
    parse.dst_header = ctx->dst_header;
    parse.dst_header_len = &payload_header_len;
    parse.src = ctx->src;
    parse.src_len = ctx->src_len;
    parse.error = ctx->error;
    if (!mode->dec.framing_parse(&parse)) {
        return 0;
    }
    dst_len -= payload_header_len;
    memcpy(ctx->dst->bytes, payload + payload_offset, dst_len);
    return dst_len;
}

// MARK: -

dp_mode_t *dp_mode_hmac_create(pp_crypto_ctx crypto,
                               pp_crypto_free_fn pp_crypto_free,
                               compression_framing_t comp_f) {

    DP_LOG("dp_mode_hmac_create");

    const dp_framing_t *frm = dp_framing(comp_f);
    const dp_mode_encrypter_t enc = {
        frm->assemble,
        dp_assemble,
        NULL,
        dp_encrypt
    };
    const dp_mode_decrypter_t dec = {
        frm->parse,
        dp_parse,
        NULL,
        dp_decrypt
    };
    const dp_mode_options_t opt = {
        comp_f,
        PacketPeerIdDisabled,
        0
    };
    return dp_mode_create_opt(crypto, pp_crypto_free, &enc, &dec, &opt);
}
