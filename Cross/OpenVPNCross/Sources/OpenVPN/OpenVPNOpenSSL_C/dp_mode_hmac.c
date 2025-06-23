//
//  dp_mode_hmac.c
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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

#include "dp_macros.h"
#include "dp_mode_hmac.h"
#include "packet.h"

static
size_t dp_assemble(void *vmode) {
    DP_LOG("dp_mode_hmac_assemble");
    const dp_mode_t *mode = vmode;
    const dp_mode_assemble_ctx *ctx = &mode->assemble_ctx;

    const size_t dst_capacity = dp_mode_assemble_capacity(mode, ctx->src_len);
    assert(ctx->dst->length >= dst_capacity);

    uint8_t *dst = ctx->dst->bytes;
    *(uint32_t *)dst = htonl(ctx->packet_id);
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

    assert(mode->enc.raw_encrypt);
    DP_ENCRYPT_BEGIN(mode->opt.peer_id)

    const size_t dst_capacity = dp_mode_encrypt_capacity(mode, ctx->src_len);
    assert(ctx->dst->length >= dst_capacity);
    uint8_t *dst = ctx->dst->bytes;

    // skip header bytes
    size_t dst_packet_len = UINT_MAX;
    crypto_error_code enc_error;
    const bool success = mode->enc.raw_encrypt(mode->crypto,
                                               dst + dst_header_len,
                                               &dst_packet_len,
                                               ctx->src,
                                               ctx->src_len,
                                               NULL,
                                               &enc_error);

    assert(dst_packet_len <= dst_capacity);//, @"Did not allocate enough bytes for payload");

    if (!success) {
        if (ctx->error) {
            ctx->error->dp_code = DataPathErrorCrypto;
            ctx->error->crypto_code = enc_error;
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

    assert(mode->dec.raw_decrypt);
    assert(ctx->src_len > 0);//, @"Decrypting an empty packet, how did it get this far?");
    assert(ctx->dst->length >= ctx->src_len);
    uint8_t *dst = ctx->dst->bytes;

    DP_DECRYPT_BEGIN(ctx)
    const crypto_t *crypto = (const crypto_t *)mode->crypto;
    if (ctx->src_len < src_header_len + crypto->meta.digest_len + crypto->meta.cipher_iv_len) {
        return 0;
    }

    // skip header = (code, key)
    size_t dst_len = UINT_MAX;
    crypto_error_code dec_error;
    const bool success = mode->dec.raw_decrypt(mode->crypto,
                                               dst,
                                               &dst_len,
                                               ctx->src + src_header_len,
                                               (int)(ctx->src_len - src_header_len),
                                               NULL,
    &dec_error);
    if (!success) {
        if (ctx->error) {
            ctx->error->dp_code = DataPathErrorCrypto;
            ctx->error->crypto_code = dec_error;
        }
        return 0;
    }
    if (has_peer_id) {
        if (peer_id != mode->opt.peer_id) {
            if (ctx->error) {
                ctx->error->dp_code = DataPathErrorPeerIdMismatch;
                ctx->error->crypto_code = CryptoErrorNone;
            }
            return 0;
        }
    }
    *ctx->dst_packet_id = ntohl(*(uint32_t *)ctx->dst->bytes);
    return dst_len;
}

static
size_t dp_parse(void *vmode) {
    DP_LOG("dp_mode_hmac_parse");
    const dp_mode_t *mode = vmode;
    const dp_mode_parse_ctx *ctx = &mode->parse_ctx;

    assert(ctx->dst->length >= ctx->src_len);

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

dp_mode_t *dp_mode_hmac_create(crypto_t *crypto,
                               crypto_free_t crypto_free,
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
    return dp_mode_create_opt(crypto, crypto_free, &enc, &dec, &opt);
}
