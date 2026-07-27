/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/conditionals.h"

#if PARTOUT_WINDOWS
#include <WinSock2.h>
#include <WS2tcpip.h>
#include <Windows.h>
#else
#include <netdb.h>
#include <sys/socket.h>
#if PARTOUT_ANDROID
#include <android/multinetwork.h>
#endif
#endif

#include <limits.h>
#include "portable/common.h"
#include "portable/dns.h"

static int local_getaddrinfo(const char *hostname,
                             const char *service,
                             const struct addrinfo *hints,
                             const pp_reachability *reachability,
                             struct addrinfo **result) {
#if PARTOUT_ANDROID
    if (!reachability || reachability->network_handle == 0) {
        return EAI_FAIL;
    }
    return android_getaddrinfofornetwork(reachability->network_handle,
                                         hostname,
                                         service,
                                         hints,
                                         result);
#else
    (void)reachability;
    return getaddrinfo(hostname, service, hints, result);
#endif
}

int pp_dns_resolve(const char *hostname,
                   const char *service,
                   bool all_addresses,
                   const pp_reachability *reachability,
                   pp_dns_result *result) {
    struct addrinfo hints;
    struct addrinfo *native_result = NULL;
    pp_zero(&hints, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
#if PARTOUT_APPLE && defined(AI_ALL)
    if (all_addresses) {
        hints.ai_flags |= AI_ALL;
    }
#else
    (void)all_addresses;
#endif
    const int status = local_getaddrinfo(hostname,
                                         service,
                                         &hints,
                                         reachability,
                                         &native_result);
    *result = (pp_dns_result)native_result;
    return status;
}

void pp_dns_result_free(pp_dns_result result) {
    if (!result) return;
    freeaddrinfo((struct addrinfo *)result);
}

pp_dns_result pp_dns_result_next(pp_dns_result result) {
    if (!result) return NULL;
    const struct addrinfo *native_result = (const struct addrinfo *)result;
    return (pp_dns_result)native_result->ai_next;
}

size_t pp_dns_address_string_max(void) {
    return 128;
}

bool pp_dns_address_string(pp_dns_result result,
                           char *dst,
                           size_t dst_len,
                           bool *is_ipv6) {
    if (!result || !dst || dst_len == 0 || !is_ipv6) return false;
    const struct addrinfo *native_result = (const struct addrinfo *)result;
    if (!native_result->ai_addr) return false;
#if PARTOUT_WINDOWS
    if (native_result->ai_addrlen > INT_MAX || dst_len > UINT32_MAX) return false;
    const int status = getnameinfo(native_result->ai_addr,
                                   (int)native_result->ai_addrlen,
                                   dst,
                                   (DWORD)dst_len,
                                   NULL,
                                   0,
                                   NI_NUMERICHOST);
#else
    const int status = getnameinfo(native_result->ai_addr,
                                   native_result->ai_addrlen,
                                   dst,
                                   (socklen_t)dst_len,
                                   NULL,
                                   0,
                                   NI_NUMERICHOST);
#endif
    if (status != 0) return false;
    *is_ipv6 = native_result->ai_family == AF_INET6;
    return true;
}

bool pp_dns_error_is_bad_flags(int error_code) {
#ifdef EAI_BADFLAGS
    return error_code == EAI_BADFLAGS;
#else
    (void)error_code;
    return false;
#endif
}
