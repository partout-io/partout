/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
#pragma once
#include <stdint.h>

/* Numeric, platform-independent endpoint. Zero-initialize before use.
 * family is 4 or 6 (not AF_*). address contains network-order bytes, with
 * IPv4 in its first four bytes. port and scope_id are in host byte order.
 * scope_id is an IPv6 interface index; it must be zero for IPv4.
 * IPv4-mapped IPv6 addresses are normalized to IPv4 by the bridge. */
typedef struct wg_endpoint {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} wg_endpoint;

enum {
    WG_IO_OK = 0,
    WG_IO_INVALID = -1,
    WG_IO_CLOSED = -2,
    WG_IO_QUEUE_FULL = -3
};

/* Go -> host: transmit one UDP datagram. Return zero once copied/accepted,
 * nonzero on failure. The callback may run concurrently on Go worker threads.
 * packet and destination are borrowed only until return. Copy both if queued.
 * It must return promptly and must not call back into the WireGuard API or
 * wait for the host's lifecycle thread. No packet delivery is implied by zero.
 * Empty datagrams have size zero and may have a null packet pointer. */
typedef int32_t (*wg_write_link_fn)(void *context,
    const uint8_t *packet, uint32_t size, const wg_endpoint *destination);

/* Copied at startup. The context is host-owned and must remain valid through
 * wgTurnOffWithPassiveIO (and until host reads are detached). Go never opens
 * or closes the host socket. local_port must be the actual, nonzero bound port; listen_port must
 * be zero or match it. Port changes require a host-controlled device restart.
 * Nonzero fwmarks are unsupported; apply routing/protection in the host. */
typedef struct wg_passive_link {
    uint16_t local_port;
    wg_write_link_fn write;
} wg_passive_link;

/* Go -> host: write one decrypted raw IP packet to the tunnel. Same lifetime,
 * concurrency and non-reentrancy requirements as wg_write_link_fn. No AF or
 * virtio header is included; the host handles platform framing. */
typedef int32_t (*wg_write_tun_fn)(void *context, const uint8_t *packet, uint32_t size);

/* Copied at startup. MTU is fixed for this device lifetime (1..65535).
 * Host interface/MTU changes require restarting the device. Go owns no TUN fd
 * and emits no interface events: passive startup/shutdown control its lifetime. */
typedef struct wg_passive_tun {
    uint32_t mtu;
    wg_write_tun_fn write;
} wg_passive_tun;
