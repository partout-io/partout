/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2025 WireGuard LLC. All Rights Reserved.
 */

#pragma once

#if !PARTOUT_WINDOWS

#include <sys/types.h>
#include "wireguard/key.h"
#include "wireguard/x25519.h"

/* Redefine these manually because the <sys/kern_control.h>
 * header is not exposed to iOS */
#if PARTOUT_APPLE
#define CTLIOCGINFO 0xc0644e03UL
struct ctl_info {
    u_int32_t   ctl_id;
    char        ctl_name[96];
};
struct sockaddr_ctl {
    u_char      sc_len;
    u_char      sc_family;
    u_int16_t   ss_sysaddr;
    u_int32_t   sc_id;
    u_int32_t   sc_unit;
    u_int32_t   sc_reserved[5];
};
#endif

#endif
