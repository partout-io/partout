/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include "openvpn/packet.h"

#define DP_ENCRYPT_BEGIN(peerId) \
    const bool has_peer_id = (peerId != PacketPeerIdDisabled); \
    size_t dst_header_len = PacketOpcodeLength; \
    if (has_peer_id) { \
        dst_header_len += PacketPeerIdLength; \
    }

#define DP_DECRYPT_BEGIN(ctx) \
    const uint8_t *ptr = ctx->src; \
    openvpn_packet_code code; \
    openvpn_packet_header_get(&code, NULL, ptr); \
    uint32_t peer_id = PacketPeerIdDisabled; \
    const bool has_peer_id = (code == PacketCodeDataV2); \
    size_t src_header_len = PacketOpcodeLength; \
    if (has_peer_id) { \
        src_header_len += PacketPeerIdLength; \
        if (ctx->src_len < src_header_len) { \
            return false; \
        } \
        peer_id = openvpn_packet_header_v2_get_peer_id(ptr); \
    }

#ifdef OPENVPN_DP_DEBUG
#define DP_LOG(msg)         fprintf(stderr, "%s\n", msg)
#define DP_LOG_F(fmt, ...)  fprintf(stderr, fmt, __VA_ARGS__)
#else
#define DP_LOG(msg)         (void)0
#define DP_LOG_F(fmt, ...)  (void)0
#endif
