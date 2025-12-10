/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include "portable/lib.h"
#include "wireguard/logging.h"
#include "wireguard/wireguard.h"

/* The WireGuard API is declared as local function pointers, so
 * that we can assign them dynamically based on how the underlying
 * library is linked. */
static const char *(*fn_version)();
static void (*fn_set_logger)(void *context, pp_wg_logger_fn logger_fn);
#ifdef _WIN32
static int (*fn_turn_on)(const char *settings, const char *ifname);
#else
static int (*fn_turn_on)(const char *settings, int32_t tun_fd);
#endif
static void (*fn_turn_off)(int handle);
static int64_t (*fn_set_config)(int handle, const char *settings);
static char *(*fn_get_config)(int handle);
static void (*fn_bump_sockets)(int handle);
static void (*fn_tweak_mobile_roaming)(int handle);
#ifdef __ANDROID_API__
static int (*fn_get_socket_v4)(int handle);
static int (*fn_get_socket_v6)(int handle);
#endif

/* The Apple library is statically linked as a Swift package, except
 * when built as monolith in CMake. The functions are direct pointers
 * to the embedded symbols.
 */
#if defined(__APPLE__) && !defined(PARTOUT_MONOLITH)

#include "wg_go.h"

static inline
int load_symbols() {
    fn_version = wgVersion;
    fn_set_logger = wgSetLogger;
    fn_turn_on = wgTurnOn;
    fn_turn_off = wgTurnOff;
    fn_set_config = wgSetConfig;
    fn_get_config = wgGetConfig;
    fn_bump_sockets = wgBumpSockets;
    fn_tweak_mobile_roaming = wgDisableSomeRoamingForBrokenMobileSemantics;
    return 0;
}

#else

/* Other platforms are dynamically linked (dll/dylib/so). Here
 * we set the function pointers to the loaded library symbols.
 */
static pp_lib wg = NULL;

#define LOAD_OR_FAIL(lib, fn, symbol) \
    fn = pp_lib_load(lib, symbol); \
    if (!fn) return -1;

static inline
int load_symbols() {
    if (!wg) {
        wg = pp_lib_create("wg-go");
        if (!wg) {
            return -1;
        }
        LOAD_OR_FAIL(wg, fn_version, "wgVersion");
        LOAD_OR_FAIL(wg, fn_set_logger, "wgSetLogger");
        LOAD_OR_FAIL(wg, fn_turn_on, "wgTurnOn");
        LOAD_OR_FAIL(wg, fn_turn_off, "wgTurnOff");
        LOAD_OR_FAIL(wg, fn_set_config, "wgSetConfig");
        LOAD_OR_FAIL(wg, fn_get_config, "wgGetConfig");
        LOAD_OR_FAIL(wg, fn_bump_sockets, "wgBumpSockets");
        LOAD_OR_FAIL(wg, fn_tweak_mobile_roaming, "wgDisableSomeRoamingForBrokenMobileSemantics");
#ifdef __ANDROID_API__
        LOAD_OR_FAIL(wg, fn_get_socket_v4, "wgGetSocketV4");
        LOAD_OR_FAIL(wg, fn_get_socket_v6, "wgGetSocketV6");
#endif
    }
    return 0;
}
#endif

int pp_wg_init() {
    if (load_symbols() != 0) return -1;
    pp_clog_v(PPLogCategoryWireGuard, PPLogLevelInfo, "wg-go version: %s", pp_wg_version());
    return 0;
}

const char *pp_wg_version() {
    return fn_version();
}

void pp_wg_set_logger(void *context, pp_wg_logger_fn logger_fn) {
    return fn_set_logger(context, logger_fn);
}

#ifdef _WIN32
int pp_wg_turn_on(const char *settings, const char *ifname) {
    return fn_turn_on(settings, ifname);
}
#else
int pp_wg_turn_on(const char *settings, int32_t tun_fd) {
    return fn_turn_on(settings, tun_fd);
}
#endif

void pp_wg_turn_off(int handle) {
    fn_turn_off(handle);
}

int64_t pp_wg_set_config(int handle, const char *settings) {
    return fn_set_config(handle, settings);
}

char *pp_wg_get_config(int handle) {
    return fn_get_config(handle);
}

void pp_wg_bump_sockets(int handle) {
    return fn_bump_sockets(handle);
}

void pp_wg_tweak_mobile_roaming(int handle) {
    return fn_tweak_mobile_roaming(handle);
}

#ifdef __ANDROID_API__
int pp_wg_get_socket_v4(int handle) {
    return fn_get_socket_v4(handle);
}

int pp_wg_get_socket_v6(int handle) {
    return fn_get_socket_v6(handle);
}
#endif
