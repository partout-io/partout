/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#endif

#include "portable/network.h"

int pp_addr_string(void *dst, const size_t dst_len,
                           const void *src, const size_t src_len,
                           pp_addr_family *family) {
    if (!src) {
        return 0;
    }
    switch (src_len) {
        case 4: {
            char addressBuffer[INET_ADDRSTRLEN];
            assert(dst_len >= sizeof(addressBuffer));
            if (!inet_ntop(AF_INET, src, addressBuffer, sizeof(addressBuffer))) {
                return 0;
            }
            if (family) {
                *family = PPAddrFamilyV4;
            }
            if (dst) {
                snprintf(dst, dst_len, "%s", addressBuffer);
            }
            return 1;
        }
        case 16: {
            char addressBuffer[INET6_ADDRSTRLEN];
            assert(dst_len >= sizeof(addressBuffer));
            if (!inet_ntop(AF_INET6, src, addressBuffer, sizeof(addressBuffer))) {
                return 0;
            }
            if (family) {
                *family = PPAddrFamilyV6;
            }
            if (dst) {
                snprintf(dst, dst_len, "%s", addressBuffer);
            }
            return 1;
        }
        default: {
            return 0;
        }
    }
}

pp_addr_family pp_addr_family_of(const char *addr) {
    if (!addr) {
        return PPAddrFamilyUnknown;
    }
    unsigned char buf[sizeof(struct in6_addr)];
    if (inet_pton(AF_INET, addr, buf)) {
        return PPAddrFamilyV4;
    }
    if (inet_pton(AF_INET6, addr, buf)) {
        return PPAddrFamilyV6;
    }
    return PPAddrFamilyUnknown;
}

int pp_addr_network_v4(void *dst, const size_t dst_len,
                              const char *addr, const char *netmask) {
    if (!dst || !addr || !netmask) {
        return 0;
    }
    if (dst_len < INET_ADDRSTRLEN) {
        return 0;
    }
    struct in_addr addr_buf, mask_buf;
    if (!inet_pton(AF_INET, addr, &addr_buf)) {
        return 0;
    }
    if (!inet_pton(AF_INET, netmask, &mask_buf)) {
        return 0;
    }
    const uint32_t network = addr_buf.s_addr & mask_buf.s_addr;
    struct in_addr network_addr;
    network_addr.s_addr = network;
    return inet_ntop(AF_INET, &network_addr, dst, (socklen_t)dst_len) != NULL;
}

int pp_addr_network_v6(void *dst, const size_t dst_len,
                              const char *addr, const int prefix) {
    if (!dst || !addr) {
        return 0;
    }
    if (dst_len < INET6_ADDRSTRLEN) {
        return 0;
    }
    if (prefix < 0 || prefix > 128) {
        return 0;
    }
    struct in6_addr addr_buf;
    if (!inet_pton(AF_INET6, addr, &addr_buf)) {
        return 0;
    }
    struct in6_addr network_addr = addr_buf;
    const int network_addr_len = sizeof(struct in6_addr);
    int full_bytes = prefix / 8;
    if (full_bytes < network_addr_len) {
        const int remaining_bits = prefix % 8;

        // partial byte
        if (remaining_bits > 0) {
            uint8_t mask = 0xff << (8 - remaining_bits);
            ((uint8_t *)&network_addr)[full_bytes] &= mask;
            ++full_bytes;
        }

        // full bytes
        for (int i = full_bytes; i < network_addr_len; i++) {
            ((uint8_t *)&network_addr)[i] = 0x00;
        }
    }
    return inet_ntop(AF_INET6, &network_addr, dst, (socklen_t)dst_len) != NULL;
}
