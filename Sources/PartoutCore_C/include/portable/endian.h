/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>

#ifdef __APPLE__

#include <CoreFoundation/CoreFoundation.h>

static inline
uint16_t pp_endian_ntohs(uint16_t num) {
    return CFSwapInt16BigToHost(num);
}

static inline
uint16_t pp_endian_htons(uint16_t num) {
    return CFSwapInt16HostToBig(num);
}

static inline
uint32_t pp_endian_ntohl(uint32_t num) {
    return CFSwapInt32BigToHost(num);
}

static inline
uint32_t pp_endian_htonl(uint32_t num) {
    return CFSwapInt32HostToBig(num);
}

#else

#ifdef _WIN32
#include <WinSock2.h>
#else
#include <arpa/inet.h>
#endif

static inline
uint16_t pp_endian_ntohs(uint16_t num) {
    return ntohs(num);
}

static inline
uint16_t pp_endian_htons(uint16_t num) {
    return htons(num);
}

static inline
uint32_t pp_endian_ntohl(uint32_t num) {
    return ntohl(num);
}

static inline
uint32_t pp_endian_htonl(uint32_t num) {
    return htonl(num);
}

#endif
