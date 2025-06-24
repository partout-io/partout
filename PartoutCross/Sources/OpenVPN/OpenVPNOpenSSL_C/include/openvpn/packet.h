//
//  packet.h
//  Partout
//
//  Created by Davide De Rosa on 7/11/18.
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
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#pragma once

#include <stdint.h>
#include <string.h>
#include "crypto/endian.h"

// MARK: - Packets

#define PacketOpcodeLength          ((size_t)1)
#define PacketIdLength              ((size_t)4)
#define PacketSessionIdLength       ((size_t)8)
#define PacketAckLengthLength       ((size_t)1)
#define PacketPeerIdLength          ((size_t)3)
#define PacketPeerIdDisabled        ((uint32_t)0xffffffu)
#define PacketReplayIdLength        ((size_t)4)
#define PacketReplayTimestampLength ((size_t)4)

typedef enum {
    PacketCodeSoftResetV1           = 0x03,
    PacketCodeControlV1             = 0x04,
    PacketCodeAckV1                 = 0x05,
    PacketCodeDataV1                = 0x06,
    PacketCodeHardResetClientV2     = 0x07,
    PacketCodeHardResetServerV2     = 0x08,
    PacketCodeDataV2                = 0x09,
    PacketCodeUnknown               = 0xff
} packet_code_t;

// MARK: - Framing

#define DataPacketNoCompress        0xfa
#define DataPacketNoCompressSwap    0xfb
#define DataPacketLZOCompress       0x66

#define DataPacketV2Indicator       0x50
#define DataPacketV2Uncompressed    0x00

// MARK: - Macros

#define peer_id_masked(pid)         (pid & 0xffffff)

static inline
bool packet_is_ping(const uint8_t *_Nonnull bytes, size_t len) {
    static const uint8_t ping[] = {
        0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
        0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48
    };
    return memcmp(bytes, ping, len) == 0;
}

static inline
void packet_header_get(packet_code_t *_Nullable dst_code,
                       uint8_t *_Nullable dst_key,
                       const uint8_t *_Nonnull src) {

    if (dst_code) {
        *dst_code = (packet_code_t)(*src >> 3);
    }
    if (dst_key) {
        *dst_key = *src & 0b111;
    }
}

static inline
size_t packet_header_set(uint8_t *_Nonnull dst,
                         packet_code_t src_code,
                         uint8_t src_key,
                         const uint8_t *_Nullable src_session_id) {

    *(uint8_t *)dst = (src_code << 3) | (src_key & 0b111);
    int offset = PacketOpcodeLength;
    if (src_session_id) {
        memcpy(dst + offset, src_session_id, PacketSessionIdLength);
        offset += PacketSessionIdLength;
    }
    return offset;
}

static inline
size_t packet_header_v2_set(uint8_t *_Nonnull dst,
                            uint8_t src_key,
                            uint32_t src_peer_id) {

    *(uint32_t *)dst = ((PacketCodeDataV2 << 3) | (src_key & 0b111)) | endian_htonl(peer_id_masked(src_peer_id));
    return PacketOpcodeLength + PacketPeerIdLength;
}

static inline
uint32_t packet_header_v2_get_peer_id(const uint8_t *_Nonnull src) {
    return endian_ntohl(*(const uint32_t *)src & 0xffffff00);
}

#pragma mark - Utils

static inline
void data_swap(uint8_t *_Nonnull ptr, size_t len1, size_t len2)
{
    // two buffers due to overlapping
    uint8_t buf1[len1];
    uint8_t buf2[len2];
    memcpy(buf1, ptr, len1);
    memcpy(buf2, ptr + len1, len2);
    memcpy(ptr, buf2, len2);
    memcpy(ptr + len2, buf1, len1);
}

static inline
void data_swap_copy(uint8_t *_Nonnull dst, const uint8_t *_Nonnull src, size_t src_len, size_t len1, size_t len2) {
    assert(src_len >= len1 + len2);//, @"src is smaller than expected");
    memcpy(dst, src + len1, len2);
    memcpy(dst + len2, src, len1);
    const size_t preamble_len = len1 + len2;
    memcpy(dst + preamble_len, src + preamble_len, src_len - preamble_len);
}
