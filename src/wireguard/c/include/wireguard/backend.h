/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <stdbool.h>
#include <stdint.h>

int pp_wg_init(void);
typedef void (*pp_wg_logger_fn)(void *context, int level, const char *msg);

const char *pp_wg_version(void);
void pp_wg_set_logger(pp_wg_logger_fn logger_fn, void *context);
#if PARTOUT_WINDOWS
int pp_wg_turn_on(const char *settings, const char *ifname);
#else
int pp_wg_turn_on(const char *settings, int32_t tun_fd);
#endif
void pp_wg_turn_off(int handle);
int64_t pp_wg_set_config(int handle, const char *settings);
char *pp_wg_get_config(int handle);
void pp_wg_bump_sockets(int handle, bool sync);
void pp_wg_tweak_mobile_roaming(int handle);
#if PARTOUT_ANDROID
int pp_wg_get_socket_v4(int handle);
int pp_wg_get_socket_v6(int handle);
#endif

#include "wg_go/passive_io.h"
int32_t pp_wg_turn_on_passive(const char *, const wg_passive_link *, const wg_passive_tun *, void *);
int32_t pp_wg_receive_datagram(int32_t, const uint8_t *, uint32_t, const wg_endpoint *);
int32_t pp_wg_receive_tun_packet(int32_t, const uint8_t *, uint32_t);
