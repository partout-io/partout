/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include "portable/lib.h"
#include "wireguard/logging.h"
#include "wireguard/wireguard.h"

/* The Apple library is statically linked as a Swift package, except
 * when built as monolith in CMake. The library is dynamic everywhere
 * else.
 */
#include "wg_go.h"

int pp_wg_init() {
    pp_clog_v(PPLogCategoryWireGuard, PPLogLevelInfo, "wg-go version: %s", pp_wg_version());
    return 0;
}

const char *pp_wg_version() {
    return wgVersion();
}

void pp_wg_set_logger(void *context, pp_wg_logger_fn logger_fn) {
    return wgSetLogger(context, logger_fn);
}

#ifdef _WIN32
int pp_wg_turn_on(const char *settings, const char *ifname) {
    return wgTurnOn(settings, ifname);
}
#else
int pp_wg_turn_on(const char *settings, int32_t tun_fd) {
    return wgTurnOn(settings, tun_fd);
}
#endif

void pp_wg_turn_off(int handle) {
    wgTurnOff(handle);
}

int64_t pp_wg_set_config(int handle, const char *settings) {
    return wgSetConfig(handle, settings);
}

char *pp_wg_get_config(int handle) {
    return wgGetConfig(handle);
}

void pp_wg_bump_sockets(int handle) {
    return wgBumpSockets(handle);
}

void pp_wg_tweak_mobile_roaming(int handle) {
    return wgDisableSomeRoamingForBrokenMobileSemantics(handle);
}

#ifdef __ANDROID__
int pp_wg_get_socket_v4(int handle) {
    return wgGetSocketV4(handle);
}

int pp_wg_get_socket_v6(int handle) {
    return wgGetSocketV6(handle);
}
#endif
