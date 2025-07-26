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
    packet_code code;
    uint8_t key;
    uint8_t *_Nonnull session_id;
    uint32_t packet_id;
    uint8_t *_Nullable payload;
    size_t payload_len;
    uint32_t *_Nullable ack_ids;
    size_t ack_ids_len;
    uint8_t *_Nullable ack_remote_session_id;
} ctrl_pkt_t;

ctrl_pkt_t *_Nonnull ctrl_pkt_create(packet_code code, uint8_t key, uint32_t packet_id,
                                     const uint8_t *_Nonnull session_id,
                                     const uint8_t *_Nullable payload, size_t payload_len,
                                     const uint32_t *_Nullable ack_ids, size_t ack_ids_len,
                                     const uint8_t *_Nullable ack_remote_session_id);

void ctrl_pkt_free(ctrl_pkt_t *_Nonnull pkt);

size_t ctrl_pkt_capacity(const ctrl_pkt_t *_Nonnull pkt);

typedef struct {
    crypto_ctx _Nonnull crypto;
    uint32_t replay_id;
    uint32_t timestamp;
} ctrl_pkt_alg;

size_t ctrl_pkt_capacity(const ctrl_pkt_t *_Nonnull pkt);
size_t ctrl_pkt_capacity_alg(const ctrl_pkt_t *_Nonnull pkt, const ctrl_pkt_alg *_Nonnull alg);

size_t ctrl_pkt_serialize(uint8_t *_Nonnull dst, const ctrl_pkt_t *_Nonnull pkt);

size_t ctrl_pkt_serialize_auth(uint8_t *_Nonnull dst,
                               size_t dst_buf_len,
                               const ctrl_pkt_t *_Nonnull pkt,
                               ctrl_pkt_alg *_Nullable alg,
                               crypto_error_code *_Nullable error);

size_t ctrl_pkt_serialize_crypt(uint8_t *_Nonnull dst,
                                size_t dst_buf_len,
                                const ctrl_pkt_t *_Nonnull pkt,
                                ctrl_pkt_alg *_Nullable alg,
                                crypto_error_code *_Nullable error);
