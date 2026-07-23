/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include "portable/common.h"
#include "portable/lib.h"
#include "wireguard/backend.h"

#if PARTOUT_HAS_WIREGUARD_BACKEND

/* The Apple library is statically linked as a Swift package, except
 * when built as monolith in CMake. The library is dynamic everywhere
 * else.
 */
#include <wg_go/wg_go.h>

int pp_wg_init(void) {
    pp_clog_v(PPLogLevelInfo, "wg-go version: %s", pp_wg_version());
    return 0;
}

const char *pp_wg_version(void) {
    return wgVersion();
}

void pp_wg_set_logger(pp_wg_logger_fn logger_fn, void *context) {
    wgSetLogger(context, logger_fn);
}

#if PARTOUT_WINDOWS
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

void pp_wg_bump_sockets(int handle, bool sync) {
    if (sync) {
        wgBumpSocketsAndWait(handle);
    } else {
        wgBumpSockets(handle);
    }
}

void pp_wg_tweak_mobile_roaming(int handle) {
    wgDisableSomeRoamingForBrokenMobileSemantics(handle);
}

#if PARTOUT_ANDROID
int pp_wg_get_socket_v4(int handle) {
    return wgGetSocketV4(handle);
}

int pp_wg_get_socket_v6(int handle) {
    return wgGetSocketV6(handle);
}
#endif

#else

int pp_wg_init(void) {
    return -1;
}

const char *pp_wg_version(void) {
    return "mock";
}

void pp_wg_set_logger(pp_wg_logger_fn logger_fn, void *context) {
    (void)logger_fn;
    (void)context;
}

#if PARTOUT_WINDOWS
int pp_wg_turn_on(const char *settings, const char *ifname) {
    (void)settings;
    (void)ifname;
    return -1;
}
#else
int pp_wg_turn_on(const char *settings, int32_t tun_fd) {
    (void)settings;
    (void)tun_fd;
    return -1;
}
#endif

void pp_wg_turn_off(int handle) {
    (void)handle;
}

int64_t pp_wg_set_config(int handle, const char *settings) {
    (void)handle;
    (void)settings;
    return -1;
}

char *pp_wg_get_config(int handle) {
    (void)handle;
    return NULL;
}

void pp_wg_bump_sockets(int handle, bool sync) {
    (void)handle;
    (void)sync;
}

void pp_wg_tweak_mobile_roaming(int handle) {
    (void)handle;
}

#if PARTOUT_ANDROID
int pp_wg_get_socket_v4(int handle) {
    (void)handle;
    return -1;
}

int pp_wg_get_socket_v6(int handle) {
    (void)handle;
    return -1;
}
#endif

#endif
