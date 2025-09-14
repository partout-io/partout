/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2023 WireGuard LLC. All Rights Reserved.
 */

#pragma once

#include <stdint.h>

int pp_wg_init();

extern const char *(*pp_wg_version)();
typedef void (*pp_wg_logger_fn)(void *context, int level, const char *msg);
extern void (*pp_wg_set_logger)(void *context, pp_wg_logger_fn logger_fn);

#ifdef _WIN32
extern int (*pp_wg_turn_on)(const char *settings, const char *ifname);
#else
extern int (*pp_wg_turn_on)(const char *settings, int32_t tun_fd);
#endif
extern void (*pp_wg_turn_off)(int handle);
extern int64_t (*pp_wg_set_config)(int handle, const char *settings);
extern char *(*pp_wg_get_config)(int handle);
extern void (*pp_wg_bump_sockets)(int handle);
extern void (*pp_wg_tweak_mobile_roaming)(int handle);

#ifdef __ANDROID_API__
extern int (*pp_wg_get_socket_v4)(int handle);
extern int (*pp_wg_get_socket_v6)(int handle);
#endif
