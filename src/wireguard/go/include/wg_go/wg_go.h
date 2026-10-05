/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2023 WireGuard LLC. All Rights Reserved.
 */

#pragma once

#include <sys/types.h>
#include <stdint.h>

typedef void(*logger_fn_t)(void *context, int level, const char *msg);
extern void wgSetLogger(void *context, logger_fn_t logger_fn);
#ifdef _WIN32
extern int wgTurnOn(const char *settings, const char *ifname);
#else
extern int wgTurnOn(const char *settings, int32_t tun_fd);
#endif
#ifdef __ANDROID__
extern int wgGetSocketV4(int handle);
extern int wgGetSocketV6(int handle);
#endif
extern void wgTurnOff(int handle);
extern int64_t wgSetConfig(int handle, const char *settings);
extern char *wgGetConfig(int handle);
extern void wgBumpSockets(int handle);
extern void wgBumpSocketsAndWait(int handle);
extern void wgDisableSomeRoamingForBrokenMobileSemantics(int handle);
extern const char *wgVersion(void);

#include "passive_io.h"

/* Fully host-owned UDP and TUN, on every platform. No native fd or interface
 * name is consumed. Borrowed callbacks start only
 * after successful Go initialization; they may run before startup returns.
 * Before turn-off, reject new borrowed requests and complete/cancel all accepted
 * requests, then join Go. Context remains valid until
 * wgTurnOffWithPassiveIO joins callbacks and host reads have been detached.
 * Returns -1 on failure. */
extern int32_t wgTurnOnWithPassiveIO(const char *settings,
    const wg_passive_link *link, const wg_passive_tun *tun, void *context);

/* Passive handles have their own namespace. Use only passive ABI functions
 * with these handles; native wgTurnOff/wgGetConfig/etc. operate on v1 devices.
 * Configuration/MTU/listen-port changes require restarting the passive device.
 * The config string is caller-owned and must be freed with free(). */
extern void wgTurnOffWithPassiveIO(int32_t handle);
extern char *wgGetConfigWithPassiveIO(int32_t handle);
extern void wgDisableRoamingWithPassiveIO(int32_t handle);

/* Completes one accepted borrowed I/O request; not a device handle. */
extern void wgCompleteIO(uintptr_t request, uint32_t count, int32_t status);
