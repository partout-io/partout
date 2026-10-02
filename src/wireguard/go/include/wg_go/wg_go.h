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
 * name is consumed. Callbacks may run during startup; publish the returned
 * handle before delivering reads. Context remains valid until wgTurnOff joins
 * callbacks and host reads have been detached. Returns -1 on failure. */
extern int32_t wgTurnOnWithPassiveIO(const char *settings,
    const wg_passive_link *link, const wg_passive_tun *tun, void *context);

/* Host -> Go: copy one UDP datagram and its source into a bounded queue.
 * Thread-safe and never waits for queue space. Returns WG_IO_*; QUEUE_FULL
 * means this datagram was dropped. At most 256 datagrams of up to 65535 bytes
 * are queued. size zero permits a null packet. No pointers are retained.
 * Detach/synchronize host reads before transport replacement; Close/Open
 * discards queued packets but does not identify late reads from an old socket.
 * Stop/join host producers before releasing their context during shutdown. */
extern int32_t wgReceiveDatagram(int32_t handle, const uint8_t *packet,
    uint32_t size, const wg_endpoint *source);

/* Host -> Go: copy one raw IP packet read from the tunnel (1..65535 bytes).
 * Bounded to 256 packets; nonblocking and thread-safe, returns WG_IO_*.
 * QUEUE_FULL drops this packet. No pointers are retained. */
extern int32_t wgReceiveTunPacket(int32_t handle, const uint8_t *packet, uint32_t size);
