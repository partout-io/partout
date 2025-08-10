/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "crypto/crypto.h"
#include "openvpn/packet.h"

typedef struct {
    openvpn_packet_code code;
    uint8_t key;
    uint8_t *_Nonnull session_id;
    uint32_t openvpn_packet_id;
    uint8_t *_Nullable payload;
    size_t payload_len;
    uint32_t *_Nullable ack_ids;
    size_t ack_ids_len;
    uint8_t *_Nullable ack_remote_session_id;
} openvpn_ctrl_pkt;

openvpn_ctrl_pkt *_Nonnull openvpn_ctrl_pkt_create(openvpn_packet_code code, uint8_t key, uint32_t openvpn_packet_id,
                                     const uint8_t *_Nonnull session_id,
                                     const uint8_t *_Nullable payload, size_t payload_len,
                                     const uint32_t *_Nullable ack_ids, size_t ack_ids_len,
                                     const uint8_t *_Nullable ack_remote_session_id);

void openvpn_ctrl_pkt_free(openvpn_ctrl_pkt *_Nonnull pkt);

size_t openvpn_ctrl_pkt_capacity(const openvpn_ctrl_pkt *_Nonnull pkt);

typedef struct {
    pp_crypto_ctx _Nonnull crypto;
    uint32_t openvpn_replay_id;
    uint32_t timestamp;
} openvpn_ctrl_pkt_alg;

size_t openvpn_ctrl_pkt_capacity(const openvpn_ctrl_pkt *_Nonnull pkt);
size_t openvpn_ctrl_pkt_capacity_alg(const openvpn_ctrl_pkt *_Nonnull pkt, const openvpn_ctrl_pkt_alg *_Nonnull alg);

size_t openvpn_ctrl_pkt_serialize(uint8_t *_Nonnull dst, const openvpn_ctrl_pkt *_Nonnull pkt);

size_t openvpn_ctrl_pkt_serialize_auth(uint8_t *_Nonnull dst,
                               size_t dst_buf_len,
                               const openvpn_ctrl_pkt *_Nonnull pkt,
                               openvpn_ctrl_pkt_alg *_Nullable alg,
                               pp_crypto_error_code *_Nullable error);

size_t openvpn_ctrl_pkt_serialize_crypt(uint8_t *_Nonnull dst,
                                size_t dst_buf_len,
                                const openvpn_ctrl_pkt *_Nonnull pkt,
                                openvpn_ctrl_pkt_alg *_Nullable alg,
                                pp_crypto_error_code *_Nullable error);
