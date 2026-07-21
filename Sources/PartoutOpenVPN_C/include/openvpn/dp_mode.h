/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "crypto/crypto.h"
#include "openvpn/comp.h"
#include "openvpn/dp_framing.h"
#include "openvpn/packet.h"

#pragma clang assume_nonnull begin

// MARK: Outbound

// assemble -> encrypt
typedef struct {
    void *mode;
    uint32_t packet_id;
    pp_zd *dst;
    const uint8_t *src;
    size_t src_len;
} openvpn_dp_mode_assemble_ctx;

// encrypt -> SEND
typedef struct {
    uint8_t key;
    uint32_t packet_id;
    pp_zd *dst;
    const uint8_t *src;
    size_t src_len;
    openvpn_dp_error *_Nullable error;
} openvpn_dp_mode_encrypt_ctx;

typedef size_t (*openvpn_dp_mode_assemble_fn)(void *mode);
typedef size_t (*openvpn_dp_mode_encrypt_fn)(void *mode);

// MARK: - Inbound

// RECEIVE -> decrypt
typedef struct {
    pp_zd *dst;
    uint32_t *dst_packet_id;
    const uint8_t *src;
    size_t src_len;
    openvpn_dp_error *_Nullable error;
} openvpn_dp_mode_decrypt_ctx;

// decrypt -> parse
typedef struct {
    pp_zd *dst;
    uint8_t *dst_header;
    uint8_t *src; // allow parse in place
    size_t src_len;
    openvpn_dp_error *_Nullable error;
} openvpn_dp_mode_parse_ctx;

typedef size_t (*openvpn_dp_mode_decrypt_fn)(void *mode);
typedef size_t (*openvpn_dp_mode_parse_fn)(void *mode);

// MARK: - Mode

/*
 A data path mode does the following:

 - Outbound
    - Assembles packet into payload
    - Encrypts payload
    - Sends to network
 - Inbound
    - Receives from network
    - Decrypts payload
    - Parses packet from payload

 The way packets are encrypted and decrypted is delegated to
 the pp_crypto_*_t types in the CryptoOpenSSL target. On the other
 hand, the way payloads are assembled and parsed depends on
 two factors:

 - The encryption mode (AD or HMAC, where AD = associated data)
 - The compression framing (see openvpn_compression_framing)

 Only AEAD (AD) and CBC (HMAC) algorithms are supported for
 data transfer at this time.
 */

typedef struct {
    openvpn_dp_framing_assemble_fn _Nullable framing_assemble;
    openvpn_dp_mode_assemble_fn assemble;
    pp_crypto_encrypt_fn raw_encrypt;
    openvpn_dp_mode_encrypt_fn encrypt;
} openvpn_dp_mode_encrypter;

typedef struct {
    openvpn_dp_framing_parse_fn _Nullable framing_parse;
    openvpn_dp_mode_parse_fn parse;
    pp_crypto_decrypt_fn raw_decrypt;
    openvpn_dp_mode_decrypt_fn decrypt;
} openvpn_dp_mode_decrypter;

typedef struct {
    openvpn_compression_framing comp_f;
    uint32_t peer_id;
    uint16_t mss_val;
} openvpn_dp_mode_options;

typedef struct {
    void *crypto;
    pp_crypto_free_fn pp_crypto_free;
    openvpn_dp_mode_encrypter enc;
    openvpn_dp_mode_decrypter dec;
    openvpn_dp_mode_options opt;

    openvpn_dp_mode_assemble_ctx assemble_ctx;
    openvpn_dp_mode_encrypt_ctx enc_ctx;
    openvpn_dp_mode_decrypt_ctx dec_ctx;
    openvpn_dp_mode_parse_ctx parse_ctx;
} openvpn_dp_mode;

// "crypto" is owned and released on free

openvpn_dp_mode *openvpn_dp_mode_create_opt(pp_crypto_ctx crypto,
                                       pp_crypto_free_fn pp_crypto_free,
                                       const openvpn_dp_mode_encrypter *enc,
                                       const openvpn_dp_mode_decrypter *dec,
                                       const openvpn_dp_mode_options *_Nullable opt);

static inline
openvpn_dp_mode *openvpn_dp_mode_create(pp_crypto_ctx crypto,
                                   pp_crypto_free_fn pp_crypto_free,
                                   const openvpn_dp_mode_encrypter *enc,
                                   const openvpn_dp_mode_decrypter *dec) {
    return openvpn_dp_mode_create_opt(crypto, pp_crypto_free, enc, dec, NULL);
}

void openvpn_dp_mode_free(openvpn_dp_mode * _Nonnull);

static inline
uint32_t openvpn_dp_mode_peer_id(openvpn_dp_mode *mode) {
    return mode->opt.peer_id;
}

static inline
void openvpn_dp_mode_set_peer_id(openvpn_dp_mode *mode, uint32_t peer_id) {
    mode->opt.peer_id = OPENVPN_PEER_ID_MASKED(peer_id);
}

static inline
openvpn_compression_framing openvpn_dp_mode_framing(const openvpn_dp_mode *mode) {
    return mode->opt.comp_f;
}

// MARK: - Encryption

//
// AD = assemble_capacity(len)
// HMAC = assemble_capacity(len) + sizeof(uint32_t)
//
static inline
size_t openvpn_dp_mode_assemble_capacity(const openvpn_dp_mode *mode, size_t len) {
    (void)mode;
    return openvpn_dp_framing_assemble_capacity(len) + sizeof(uint32_t);
}

//
// AD = OpenVPNPacketOpcodeLength + PacketPeerIdLength + meta.encryption_capacity(len)
// HMAC = OpenVPNPacketOpcodeLength + meta.encryption_capacity(len)
//
static inline
size_t openvpn_dp_mode_encrypt_capacity(const openvpn_dp_mode *mode, size_t len) {
    const pp_crypto_ctx ctx = mode->crypto;
    const size_t max_prefix_len = OpenVPNPacketOpcodeLength + OpenVPNPacketPeerIdLength;
    const size_t enc_len = pp_crypto_encryption_capacity(ctx, len);
    return max_prefix_len + enc_len;
}

static inline
size_t openvpn_dp_mode_assemble_and_encrypt_capacity(const openvpn_dp_mode *mode, size_t len) {
    return openvpn_dp_mode_encrypt_capacity(mode, openvpn_dp_mode_assemble_capacity(mode, len));
}

size_t openvpn_dp_mode_assemble(openvpn_dp_mode *mode,
                        uint32_t packet_id,
                        pp_zd *dst,
                        const uint8_t *src,
                        size_t src_len);

size_t openvpn_dp_mode_encrypt(openvpn_dp_mode *mode,
                       uint8_t key,
                       uint32_t packet_id,
                       pp_zd *dst,
                       const uint8_t *src,
                       size_t src_len,
                       openvpn_dp_error *_Nullable error);

static inline
pp_zd *_Nullable openvpn_dp_mode_assemble_and_encrypt(openvpn_dp_mode *mode,
                                                       uint8_t key,
                                                       uint32_t packet_id,
                                                       pp_zd *buf,
                                                       const uint8_t *src,
                                                       size_t src_len,
                                                       openvpn_dp_error *_Nullable error) {

    pp_assert(buf->length >= openvpn_dp_mode_assemble_and_encrypt_capacity(mode, src_len));
    const size_t asm_len = openvpn_dp_mode_assemble(mode, packet_id, buf,
                                            src, src_len);
    if (!asm_len) {
        return NULL;
    }
    pp_zd *dst = pp_zd_create(openvpn_dp_mode_encrypt_capacity(mode, asm_len));
    const size_t dst_len = openvpn_dp_mode_encrypt(mode, key, packet_id, dst,
                                           buf->bytes, asm_len, error);
    if (!dst_len) {
        pp_zd_free(dst);
        return NULL;
    }
    pp_zd_resize(dst, dst_len);
    return dst;
}

// MARK: - Decryption

size_t openvpn_dp_mode_decrypt(openvpn_dp_mode *mode,
                       pp_zd *dst,
                       uint32_t *dst_packet_id,
                       const uint8_t *src,
                       size_t src_len,
                       openvpn_dp_error *_Nullable error);

size_t openvpn_dp_mode_parse(openvpn_dp_mode *mode,
                     pp_zd *dst,
                     uint8_t *dst_header,
                     uint8_t *src,
                     size_t src_len,
                     openvpn_dp_error *_Nullable error);

pp_zd *_Nullable openvpn_dp_mode_decrypt_and_parse(openvpn_dp_mode *mode,
                                                   pp_zd *buf,
                                                   uint32_t *dst_packet_id,
                                                   uint8_t *dst_header,
                                                   bool *dst_keep_alive,
                                                   const uint8_t *src,
                                                   size_t src_len,
                                                   openvpn_dp_error *_Nullable error);

#pragma clang assume_nonnull end
