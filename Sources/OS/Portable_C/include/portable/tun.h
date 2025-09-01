/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

/* Only available on macOS and Linux. */
#if TARGET_OS_OSX || defined(__linux)

#include "portable/socket.h"

/* Opaque tun device. */
typedef struct _pp_tun *pp_tun;

/* Lifetime. */
pp_tun _Nullable pp_tun_create(const char *_Nonnull name, uint64_t fd);
void pp_tun_free(pp_tun _Nonnull tun);

/* Associated data. */
const char *_Nonnull pp_tun_name(pp_tun _Nonnull tun);
pp_socket _Nonnull pp_tun_socket(pp_tun _Nonnull tun);

/* Platform-specific implementation to request a new tun device. */
pp_tun _Nullable pp_tun_open();

#endif
