/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "openvpn/dp_macros.h"
#include "openvpn/dp_mode.h"
#include "openvpn/packet.h"

openvpn_dp_mode *openvpn_dp_mode_create_opt(pp_crypto_ctx crypto,
                              pp_crypto_free_fn pp_crypto_free,
                              const openvpn_dp_mode_encrypter *enc,
                              const openvpn_dp_mode_decrypter *dec,
                              const openvpn_dp_mode_options *opt) {
    OPENVPN_DP_LOG("openvpn_dp_mode_create_opt");

    openvpn_dp_mode *mode = pp_alloc(sizeof(openvpn_dp_mode));
    mode->crypto = crypto;
    mode->pp_crypto_free = pp_crypto_free;
    if (opt) {
        mode->opt = *opt;
    } else {
        mode->opt.comp_f = OpenVPNCompressionFramingDisabled;
        mode->opt.peer_id = OpenVPNPacketPeerIdDisabled;
        mode->opt.mss_val = 0;
    }

    // extend with raw crypto functions
    mode->enc = *enc;
    mode->dec = *dec;
    mode->enc.raw_encrypt = crypto->base.encrypter.encrypt;
    mode->dec.raw_decrypt = crypto->base.decrypter.decrypt;

    return mode;
}

void openvpn_dp_mode_free(openvpn_dp_mode *mode) {
    OPENVPN_DP_LOG("openvpn_dp_mode_free");
    mode->pp_crypto_free(mode->crypto);
    pp_free(mode);
}

// MARK: - Encryption

size_t openvpn_dp_mode_assemble(openvpn_dp_mode *_Nonnull mode,
                        uint32_t packet_id,
                        pp_zd *_Nonnull dst,
                        const uint8_t *_Nonnull src,
                        size_t src_len) {

    openvpn_dp_mode_assemble_ctx *ctx = &mode->assemble_ctx;
    ctx->mode = mode;
    ctx->packet_id = packet_id;
    ctx->dst = dst;
    ctx->src = src;
    ctx->src_len = src_len;
    return mode->enc.assemble(mode);
}

size_t openvpn_dp_mode_encrypt(openvpn_dp_mode *_Nonnull mode,
                       uint8_t key,
                       uint32_t packet_id,
                       pp_zd *_Nonnull dst,
                       const uint8_t *_Nonnull src,
                       size_t src_len,
                       openvpn_dp_error *_Nullable error) {

    openvpn_dp_mode_encrypt_ctx *ctx = &mode->enc_ctx;
    ctx->key = key;
    ctx->packet_id = packet_id;
    ctx->dst = dst;
    ctx->src = src;
    ctx->src_len = src_len;
    ctx->error = error;
    return mode->enc.encrypt(mode);
}

// MARK: - Decryption

size_t openvpn_dp_mode_decrypt(openvpn_dp_mode *_Nonnull mode,
                       pp_zd *_Nonnull dst,
                       uint32_t *_Nonnull dst_packet_id,
                       const uint8_t *_Nonnull src,
                       size_t src_len,
                       openvpn_dp_error *_Nullable error) {

    openvpn_dp_mode_decrypt_ctx *ctx = &mode->dec_ctx;
    ctx->dst = dst;
    ctx->dst_packet_id = dst_packet_id;
    ctx->src = src;
    ctx->src_len = src_len;
    ctx->error = error;
    return mode->dec.decrypt(mode);
}

size_t openvpn_dp_mode_parse(openvpn_dp_mode *_Nonnull mode,
                     pp_zd *_Nonnull dst,
                     uint8_t *_Nonnull dst_header,
                     uint8_t *_Nonnull src,
                     size_t src_len,
                     openvpn_dp_error *_Nullable error) {

    openvpn_dp_mode_parse_ctx *ctx = &mode->parse_ctx;
    ctx->dst_header = dst_header;
    ctx->dst = dst;
    ctx->src = src;
    ctx->src_len = src_len;
    ctx->error = error;
    return mode->dec.parse(mode);
}
