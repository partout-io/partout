/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
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
    uint32_t packet_id;
    uint8_t *_Nullable payload;
    size_t payload_len;
    uint32_t *_Nullable ack_ids;
    size_t ack_ids_len;
    uint8_t *_Nullable ack_remote_session_id;
} openvpn_ctrl;

openvpn_ctrl *_Nonnull openvpn_ctrl_create(openvpn_packet_code code, uint8_t key, uint32_t packet_id,
                                     const uint8_t *_Nonnull session_id,
                                     const uint8_t *_Nullable payload, size_t payload_len,
                                     const uint32_t *_Nullable ack_ids, size_t ack_ids_len,
                                     const uint8_t *_Nullable ack_remote_session_id);

void openvpn_ctrl_free(openvpn_ctrl *_Nonnull pkt);

size_t openvpn_ctrl_capacity(const openvpn_ctrl *_Nonnull pkt);

typedef struct {
    pp_crypto_ctx _Nonnull crypto;
    uint32_t replay_id;
    uint32_t timestamp;
} openvpn_ctrl_alg;

size_t openvpn_ctrl_capacity(const openvpn_ctrl *_Nonnull pkt);
size_t openvpn_ctrl_capacity_alg(const openvpn_ctrl *_Nonnull pkt, const openvpn_ctrl_alg *_Nonnull alg);

size_t openvpn_ctrl_serialize(uint8_t *_Nonnull dst, const openvpn_ctrl *_Nonnull pkt);

size_t openvpn_ctrl_serialize_auth(uint8_t *_Nonnull dst,
                               size_t dst_buf_len,
                               const openvpn_ctrl *_Nonnull pkt,
                               openvpn_ctrl_alg *_Nullable alg,
                               pp_crypto_error_code *_Nullable error);

size_t openvpn_ctrl_serialize_crypt(uint8_t *_Nonnull dst,
                                size_t dst_buf_len,
                                const openvpn_ctrl *_Nonnull pkt,
                                openvpn_ctrl_alg *_Nullable alg,
                                pp_crypto_error_code *_Nullable error);
