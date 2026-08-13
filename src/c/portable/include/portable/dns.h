/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include "portable/socket.h"

#pragma clang assume_nonnull begin

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
