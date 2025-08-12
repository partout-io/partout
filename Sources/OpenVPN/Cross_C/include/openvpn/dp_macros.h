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

#define OPENVPN_DP_ENCRYPT_BEGIN(peerId) \
    const bool has_peer_id = (peerId != OpenVPNPacketPeerIdDisabled); \
    size_t dst_header_len = OpenVPNPacketOpcodeLength; \
    if (has_peer_id) { \
        dst_header_len += OpenVPNPacketPeerIdLength; \
    }

#define OPENVPN_DP_DECRYPT_BEGIN(ctx) \
    const uint8_t *ptr = ctx->src; \
    openvpn_packet_code code; \
    openvpn_packet_header_get(&code, NULL, ptr); \
    uint32_t peer_id = OpenVPNPacketPeerIdDisabled; \
    const bool has_peer_id = (code == OpenVPNPacketCodeDataV2); \
    size_t src_header_len = OpenVPNPacketOpcodeLength; \
    if (has_peer_id) { \
        src_header_len += OpenVPNPacketPeerIdLength; \
        if (ctx->src_len < src_header_len) { \
            return false; \
        } \
        peer_id = openvpn_packet_header_v2_get_peer_id(ptr); \
    }

#ifdef OPENVPN_DP_DEBUG
#define OPENVPN_DP_LOG(msg)         fprintf(stderr, "%s\n", msg)
#define OPENVPN_DP_LOG_F(fmt, ...)  fprintf(stderr, fmt, __VA_ARGS__)
#else
#define OPENVPN_DP_LOG(msg)         (void)0
#define OPENVPN_DP_LOG_F(fmt, ...)  (void)0
#endif
