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
/* The profile UUID is copied at startup; callback strings are borrowed. */
typedef void (*pp_wg_logger_fn)(const char *profile_id, int level, const char *msg);

const char *pp_wg_version(void);
#if PARTOUT_WINDOWS
int pp_wg_turn_on(const char *settings, const char *ifname, pp_wg_logger_fn logger, const char *profile_id);
#else
int pp_wg_turn_on(const char *settings, int32_t tun_fd, pp_wg_logger_fn logger, const char *profile_id);
#endif
void pp_wg_turn_off(int handle);
int64_t pp_wg_set_config(int handle, const char *settings);
char *pp_wg_get_config(int handle);
void pp_wg_bump_sockets(int handle, bool sync);
void pp_wg_tweak_mobile_roaming(int handle);
void pp_wg_send_keepalives(int handle);
#if PARTOUT_ANDROID
int pp_wg_get_socket_v4(int handle);
int pp_wg_get_socket_v6(int handle);
#endif

#include "wg_go/passive_io.h"
int32_t pp_wg_turn_on_passive(const char *, const wg_passive_link *, const wg_passive_tun *, void *, pp_wg_logger_fn, const char *);

void pp_wg_complete_io(uintptr_t, uint32_t, int32_t);
