/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */
#include <assert.h>
#include <string.h>
#include "portable/common.h"
#include "wireguard/backend.h"
#include "wg_go/wg_go.h"

static unsigned native_off, passive_off, native_config, passive_config;
static unsigned native_bump, native_roaming, passive_roaming, passive_keepalives;

void pp_clog_v(pp_log_level level, const char *fmt, ...) { (void)level; (void)fmt; }
const char *wgVersion(void) { return "test"; }
void wgSetLogger(void *ctx, logger_fn_t logger) { (void)ctx; (void)logger; }
#ifdef _WIN32
int wgTurnOn(const char *settings, const char *ifname) { (void)ifname;
#else
int wgTurnOn(const char *settings, int32_t fd) { (void)fd;
#endif
    return strcmp(settings, "fail") == 0 ? -1 : 7;
}
int32_t wgTurnOnWithPassiveIO(const char *settings, const wg_passive_link *link,
    const wg_passive_tun *tun, void *ctx) {
    (void)link; (void)tun; (void)ctx;
    return strcmp(settings, "fail") == 0 ? -1 : 7;
}
void wgTurnOff(int handle) { assert(handle == 7); ++native_off; }
void wgTurnOffWithPassiveIO(int32_t handle) { assert(handle == 7); ++passive_off; }
int64_t wgSetConfig(int handle, const char *settings) {
    assert(handle == 7); (void)settings; ++native_config; return 0;
}
int64_t wgSetEndpointsWithPassiveIO(int32_t handle, const char *settings) {
    assert(handle == 7); (void)settings; ++passive_config; return 0;
}
char *wgGetConfig(int handle) { assert(handle == 7); return "native"; }
char *wgGetConfigWithPassiveIO(int32_t handle) { assert(handle == 7); return "passive"; }
void wgBumpSockets(int handle) { assert(handle == 7); ++native_bump; }
void wgBumpSocketsAndWait(int handle) { wgBumpSockets(handle); }
void wgDisableSomeRoamingForBrokenMobileSemantics(int handle) { assert(handle == 7); ++native_roaming; }
void wgDisableRoamingWithPassiveIO(int32_t handle) { assert(handle == 7); ++passive_roaming; }
void wgSendKeepalivesWithPassiveIO(int32_t handle) { assert(handle == 7); ++passive_keepalives; }
void wgCompleteIO(uintptr_t request, uint32_t count, int32_t status) { (void)request; (void)count; (void)status; }
#ifdef __ANDROID__
int wgGetSocketV4(int handle) { assert(handle == 7); return 3; }
int wgGetSocketV6(int handle) { assert(handle == 7); return 4; }
#endif

static int start_native(const char *settings) {
#if PARTOUT_WINDOWS
    return pp_wg_turn_on(settings, "test");
#else
    return pp_wg_turn_on(settings, -1);
#endif
}

static void exercise(const char *mode) {
    assert(strcmp(pp_wg_get_config(7), mode) == 0);
    assert(pp_wg_set_config(7, "") == 0);
    pp_wg_bump_sockets(7, false);
    pp_wg_bump_sockets(7, true);
    pp_wg_tweak_mobile_roaming(7);
    pp_wg_send_keepalives(7);
}

int main(void) {
    assert(start_native("") == 7);
    assert(pp_wg_turn_on_passive("fail", NULL, NULL, NULL) == -1);
    exercise("native"); // Failed opposite-mode startup must not change dispatch.
    pp_wg_turn_off(7);
    assert(native_off == 1 && passive_off == 0);
    assert(native_config == 1 && passive_config == 0 && native_bump == 2);
    assert(native_roaming == 1 && passive_roaming == 0 && passive_keepalives == 0);

    assert(pp_wg_turn_on_passive("", NULL, NULL, NULL) == 7);
    assert(start_native("fail") == -1);
    exercise("passive"); // Identical handles belong to independent registries.
    pp_wg_turn_off(7);
    assert(native_off == 1 && passive_off == 1);
    assert(native_config == 1 && passive_config == 1 && native_bump == 2);
    assert(native_roaming == 1 && passive_roaming == 1 && passive_keepalives == 1);

    assert(start_native("") == 7);
    exercise("native");
    pp_wg_turn_off(7);
    assert(native_off == 2 && passive_off == 1 && native_bump == 4);
    return 0;
}
