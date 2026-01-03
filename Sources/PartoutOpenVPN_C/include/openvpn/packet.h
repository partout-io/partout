/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>
#include <string.h>
#include "portable/common.h"
#include "portable/endian.h"

// MARK: - Packets

#define OpenVPNPacketOpcodeLength          ((size_t)1)
#define OpenVPNPacketIdLength              ((size_t)4)
#define OpenVPNPacketSessionIdLength       ((size_t)8)
#define OpenVPNPacketAckLengthLength       ((size_t)1)
#define OpenVPNPacketPeerIdLength          ((size_t)3)
#define OpenVPNPacketPeerIdDisabled        ((uint32_t)0xffffffu)
#define OpenVPNPacketReplayIdLength        ((size_t)4)
#define OpenVPNPacketReplayTimestampLength ((size_t)4)

typedef enum {
    OpenVPNPacketCodeSoftResetV1           = 0x03,
    OpenVPNPacketCodeControlV1             = 0x04,
    OpenVPNPacketCodeAckV1                 = 0x05,
    OpenVPNPacketCodeDataV1                = 0x06,
    OpenVPNPacketCodeHardResetClientV2     = 0x07,
    OpenVPNPacketCodeHardResetServerV2     = 0x08,
    OpenVPNPacketCodeDataV2                = 0x09,
    OpenVPNPacketCodeUnknown               = 0xff
} openvpn_packet_code;

// MARK: - Framing

#define OpenVPNDataPacketNoCompress        0xfa
#define OpenVPNDataPacketNoCompressSwap    0xfb
#define OpenVPNDataPacketLZOCompress       0x66

#define OpenVPNDataPacketV2Indicator       0x50
#define OpenVPNDataPacketV2Uncompressed    0x00

// MARK: - Macros

#define OPENVPN_PEER_ID_MASKED(pid)        (pid & 0xffffff)

static inline
bool openvpn_packet_is_ping(const uint8_t *_Nonnull bytes, size_t len) {
    static const uint8_t ping[] = {
        0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
        0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48
    };
    return len == sizeof(ping) && !memcmp(bytes, ping, len);
}

static inline
void openvpn_packet_header_get(openvpn_packet_code *_Nullable dst_code,
                       uint8_t *_Nullable dst_key,
                       const uint8_t *_Nonnull src) {

    if (dst_code) {
        *dst_code = (openvpn_packet_code)(*src >> 3);
    }
    if (dst_key) {
        *dst_key = *src & 0b111;
    }
}

static inline
size_t openvpn_packet_header_set(uint8_t *_Nonnull dst,
                         openvpn_packet_code src_code,
                         uint8_t src_key,
                         const uint8_t *_Nullable src_session_id) {

    *(uint8_t *)dst = (src_code << 3) | (src_key & 0b111);
    int offset = OpenVPNPacketOpcodeLength;
    if (src_session_id) {
        memcpy(dst + offset, src_session_id, OpenVPNPacketSessionIdLength);
        offset += OpenVPNPacketSessionIdLength;
    }
    return offset;
}

static inline
size_t openvpn_packet_header_v2_set(uint8_t *_Nonnull dst,
                            uint8_t src_key,
                            uint32_t src_peer_id) {

    *(uint32_t *)dst = ((OpenVPNPacketCodeDataV2 << 3) | (src_key & 0b111)) | pp_endian_htonl(OPENVPN_PEER_ID_MASKED(src_peer_id));
    return OpenVPNPacketOpcodeLength + OpenVPNPacketPeerIdLength;
}

static inline
uint32_t openvpn_packet_header_v2_get_peer_id(const uint8_t *_Nonnull src) {
    return pp_endian_ntohl(*(const uint32_t *)src & 0xffffff00);
}

#pragma mark - Utils

static inline
void openvpn_data_swap(uint8_t *_Nonnull ptr, size_t len1, size_t len2)
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
void openvpn_data_swap_copy(uint8_t *_Nonnull dst, const uint8_t *_Nonnull src, size_t src_len, size_t len1, size_t len2) {
    pp_assert(src_len >= len1 + len2);//, @"src is smaller than expected");
    memcpy(dst, src + len1, len2);
    memcpy(dst + len2, src, len1);
    const size_t preamble_len = len1 + len2;
    memcpy(dst + preamble_len, src + preamble_len, src_len - preamble_len);
}
