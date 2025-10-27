/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>
#include <stdlib.h>

#ifdef _WIN32
#include <WinSock2.h>
#else
#include <arpa/inet.h>
#include <net/if.h>
#include <netdb.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#endif

typedef enum {
    PPAddrFamilyUnknown,
    PPAddrFamilyV4 = 4,
    PPAddrFamilyV6 = 6
} pp_addr_family;

// data -> string
int pp_addr_string(void *dst,
                   const size_t dst_len,
                   const void *src,
                   const size_t src_len,
                   pp_addr_family *family);

// string -> family
pp_addr_family pp_addr_family_of(const char *addr);

int pp_addr_network_v4(void *dst, const size_t dst_len,
                       const char *addr, const char *netmask);

int pp_addr_network_v6(void *dst, const size_t dst_len,
                       const char *addr, const int prefix);

static inline uint32_t pp_swap_big32_to_host(uint32_t x) {
    return ntohl(x);
}
