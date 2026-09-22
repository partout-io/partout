/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "portable/conditionals.h"

#pragma clang assume_nonnull begin

/* Network reachability. */
typedef struct {
    bool reachable;
#if PARTOUT_ANDROID
    uint64_t network_handle;
#endif
} pp_reachability;
static inline pp_reachability pp_reachability_none(void) {
#if PARTOUT_ANDROID
    static const pp_reachability none = {
        .reachable = false,
        .network_handle = 0
    };
#else
    static const pp_reachability none = {
        .reachable = false
    };
#endif
    return none;
}

/* Opaque wrapper around the platform-native addrinfo list. */
typedef struct __pp_dns_result *pp_dns_result;

int pp_dns_resolve(const char *hostname,
                   const char *_Nullable service,
                   bool all_addresses,
                   const pp_reachability *_Nullable reachability,
                   pp_dns_result _Nullable *_Nonnull result);
void pp_dns_result_free(pp_dns_result result);
pp_dns_result _Nullable pp_dns_result_next(pp_dns_result result);
size_t pp_dns_address_string_max(void);
bool pp_dns_address_string(pp_dns_result result,
                           char *dst,
                           size_t dst_len,
                           bool *is_ipv6);
bool pp_dns_error_is_bad_flags(int error_code);

#pragma clang assume_nonnull end
