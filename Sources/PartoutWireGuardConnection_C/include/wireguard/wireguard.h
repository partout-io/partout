/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>

int pp_wg_init();
typedef void (*pp_wg_logger_fn)(void *context, int level, const char *msg);

const char *pp_wg_version();
void pp_wg_set_logger(void *context, pp_wg_logger_fn logger_fn);
#ifdef _WIN32
int pp_wg_turn_on(const char *settings, const char *ifname);
#else
int pp_wg_turn_on(const char *settings, int32_t tun_fd);
#endif
void pp_wg_turn_off(int handle);
int64_t pp_wg_set_config(int handle, const char *settings);
char *pp_wg_get_config(int handle);
void pp_wg_bump_sockets(int handle);
void pp_wg_tweak_mobile_roaming(int handle);
#ifdef __ANDROID__
int pp_wg_get_socket_v4(int handle);
int pp_wg_get_socket_v6(int handle);
#endif
