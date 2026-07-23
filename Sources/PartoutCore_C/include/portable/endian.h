/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "conditionals.h"

#include <stdint.h>

#if PARTOUT_APPLE

static inline
uint16_t pp_endian_ntohs(uint16_t num) {
    return __builtin_bswap16(num);
}

static inline
uint16_t pp_endian_htons(uint16_t num) {
    return __builtin_bswap16(num);
}

static inline
uint32_t pp_endian_ntohl(uint32_t num) {
    return __builtin_bswap32(num);
}

static inline
uint32_t pp_endian_htonl(uint32_t num) {
    return __builtin_bswap32(num);
}

#else

#if !PARTOUT_WINDOWS
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
