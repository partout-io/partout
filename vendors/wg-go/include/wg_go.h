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
extern void wgDisableSomeRoamingForBrokenMobileSemantics(int handle);
extern const char *wgVersion();
