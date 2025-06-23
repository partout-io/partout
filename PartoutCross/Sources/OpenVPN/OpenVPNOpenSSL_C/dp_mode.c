//
//  dp_mode.c
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

#include "crypto_openssl/allocation.h"
#include "openvpn/dp_macros.h"
#include "openvpn/dp_mode.h"
#include "openvpn/packet.h"

dp_mode_t *dp_mode_create_opt(crypto_t *crypto,
                              crypto_free_t crypto_free,
                              const dp_mode_encrypter_t *enc,
                              const dp_mode_decrypter_t *dec,
                              const dp_mode_options_t *opt) {
    DP_LOG("dp_mode_create_opt");

    dp_mode_t *mode = pp_alloc_crypto(sizeof(dp_mode_t));
    mode->crypto = crypto;
    mode->crypto_free = crypto_free;
    if (opt) {
        mode->opt = *opt;
    } else {
        mode->opt.comp_f = CompressionFramingDisabled;
        mode->opt.peer_id = PacketPeerIdDisabled;
        mode->opt.mss_val = 0;
    }

    // extend with raw crypto functions
    mode->enc = *enc;
    mode->dec = *dec;
    mode->enc.raw_encrypt = crypto->encrypter.encrypt;
    mode->dec.raw_decrypt = crypto->decrypter.decrypt;

    return mode;
}

void dp_mode_free(dp_mode_t *mode) {
    DP_LOG("dp_mode_free");
    mode->crypto_free(mode->crypto);
    free(mode);
}

// MARK: - Encryption

size_t dp_mode_assemble(dp_mode_t *_Nonnull mode,
                        uint32_t packet_id,
                        zeroing_data_t *_Nonnull dst,
                        const uint8_t *_Nonnull src,
                        size_t src_len) {

    dp_mode_assemble_ctx *ctx = &mode->assemble_ctx;
    ctx->mode = mode;
    ctx->packet_id = packet_id;
    ctx->dst = dst;
    ctx->src = src;
    ctx->src_len = src_len;
    return mode->enc.assemble(mode);
}

size_t dp_mode_encrypt(dp_mode_t *_Nonnull mode,
                       uint8_t key,
                       uint32_t packet_id,
                       zeroing_data_t *_Nonnull dst,
                       const uint8_t *_Nonnull src,
                       size_t src_len,
                       dp_error_t *_Nullable error) {

    dp_mode_encrypt_ctx *ctx = &mode->enc_ctx;
    ctx->key = key;
    ctx->packet_id = packet_id;
    ctx->dst = dst;
    ctx->src = src;
    ctx->src_len = src_len;
    ctx->error = error;
    return mode->enc.encrypt(mode);
}

// MARK: - Decryption

size_t dp_mode_decrypt(dp_mode_t *_Nonnull mode,
                       zeroing_data_t *_Nonnull dst,
                       uint32_t *_Nonnull dst_packet_id,
                       const uint8_t *_Nonnull src,
                       size_t src_len,
                       dp_error_t *_Nullable error) {

    dp_mode_decrypt_ctx *ctx = &mode->dec_ctx;
    ctx->dst = dst;
    ctx->dst_packet_id = dst_packet_id;
    ctx->src = src;
    ctx->src_len = src_len;
    ctx->error = error;
    return mode->dec.decrypt(mode);
}

size_t dp_mode_parse(dp_mode_t *_Nonnull mode,
                     zeroing_data_t *_Nonnull dst,
                     uint8_t *_Nonnull dst_header,
                     uint8_t *_Nonnull src,
                     size_t src_len,
                     dp_error_t *_Nullable error) {

    dp_mode_parse_ctx *ctx = &mode->parse_ctx;
    ctx->dst_header = dst_header;
    ctx->dst = dst;
    ctx->src = src;
    ctx->src_len = src_len;
    ctx->error = error;
    return mode->dec.parse(mode);
}
