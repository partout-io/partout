//
//  dp_macros.h
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
    packet_code code; \
    packet_header_get(&code, NULL, ptr); \
    uint32_t peer_id = PacketPeerIdDisabled; \
    const bool has_peer_id = (code == PacketCodeDataV2); \
    size_t src_header_len = PacketOpcodeLength; \
    if (has_peer_id) { \
        src_header_len += PacketPeerIdLength; \
        if (ctx->src_len < src_header_len) { \
            return false; \
        } \
        peer_id = packet_header_v2_get_peer_id(ptr); \
    }

#ifdef OPENVPN_DP_DEBUG
#define DP_LOG(msg)         fprintf(stderr, "%s\n", msg)
#define DP_LOG_F(fmt, ...)  fprintf(stderr, fmt, __VA_ARGS__)
#else
#define DP_LOG(msg)         (void)0
#define DP_LOG_F(fmt, ...)  (void)0
#endif
