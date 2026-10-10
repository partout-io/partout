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
#include <stdatomic.h>

/* One backend mode is active at a time. Drain previous-mode calls before
 * switching: the independent Go registries can return overlapping handles. */
static atomic_bool passive_mode = false;

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
    int handle = wgTurnOn(settings, ifname);
    if (handle >= 0) atomic_store(&passive_mode, false);
    return handle;
}
#else
int pp_wg_turn_on(const char *settings, int32_t tun_fd) {
    int handle = wgTurnOn(settings, tun_fd);
    if (handle >= 0) atomic_store(&passive_mode, false);
    return handle;
}
#endif

void pp_wg_turn_off(int handle) {
    if (atomic_load(&passive_mode)) {
        wgTurnOffWithPassiveIO(handle);
    } else {
        wgTurnOff(handle);
    }
}

int64_t pp_wg_set_config(int handle, const char *settings) {
    return atomic_load(&passive_mode)
        ? wgSetEndpointsWithPassiveIO(handle, settings)
        : wgSetConfig(handle, settings);
}

char *pp_wg_get_config(int handle) {
    return atomic_load(&passive_mode)
        ? wgGetConfigWithPassiveIO(handle)
        : wgGetConfig(handle);
}

void pp_wg_bump_sockets(int handle, bool sync) {
    if (atomic_load(&passive_mode)) return;
    if (sync) {
        wgBumpSocketsAndWait(handle);
    } else {
        wgBumpSockets(handle);
    }
}

void pp_wg_tweak_mobile_roaming(int handle) {
    if (atomic_load(&passive_mode)) {
        wgDisableRoamingWithPassiveIO(handle);
    } else {
        wgDisableSomeRoamingForBrokenMobileSemantics(handle);
    }
}

#if PARTOUT_ANDROID
int pp_wg_get_socket_v4(int handle) {
    return atomic_load(&passive_mode) ? -1 : wgGetSocketV4(handle);
}

int pp_wg_get_socket_v6(int handle) {
    return atomic_load(&passive_mode) ? -1 : wgGetSocketV6(handle);
}
#endif

int32_t pp_wg_turn_on_passive(const char *settings, const wg_passive_link *link, const wg_passive_tun *tun, void *context) {
    int32_t handle = wgTurnOnWithPassiveIO(settings, link, tun, context);
    if (handle >= 0) atomic_store(&passive_mode, true);
    return handle;
}

int64_t pp_wg_set_endpoints_passive(int32_t handle, const char *settings) {
    return wgSetEndpointsWithPassiveIO(handle, settings);
}

void pp_wg_send_keepalives(int handle) {
    if (atomic_load(&passive_mode)) wgSendKeepalivesWithPassiveIO(handle);
}

void pp_wg_complete_io(uintptr_t request, uint32_t count, int32_t status) {
    wgCompleteIO(request, count, status);
}

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

int32_t pp_wg_turn_on_passive(const char *settings, const wg_passive_link *link, const wg_passive_tun *tun, void *context) {
    (void)settings; (void)link; (void)tun; (void)context;
    return -1;
}

int64_t pp_wg_set_endpoints_passive(int32_t handle, const char *settings) {
    (void)handle; (void)settings;
    return -1;
}

void pp_wg_send_keepalives(int handle) {
    (void)handle;
}

void pp_wg_complete_io(uintptr_t request, uint32_t count, int32_t status) {
    (void)request; (void)count; (void)status;
}

#endif
