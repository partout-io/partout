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
    WG_IO_MAX_BATCH = 256,
    WG_IO_OK = 0,
    WG_IO_INVALID = -1,
    WG_IO_CLOSED = -2,
    WG_IO_QUEUE_FULL = -3
};

/* Payload view. Synchronous APIs borrow until return; asynchronous writes
 * borrow descriptors and payloads until completion. */
typedef struct wg_packet {
    const uint8_t *data;
    uint32_t size;
} wg_packet;

/* Asynchronous borrowed I/O. Zero accepts the request and requires exactly one
 * wgCompleteIO(request, completed_count, status), possibly before return.
 * Nonzero rejects it and MUST NOT complete it. The host must release all
 * descriptors/payloads before completion. Cancellation completes with CLOSED.
 * Callbacks only submit work; they never wait for the looper. Before turn-off,
 * reject new requests and complete/cancel every accepted request.
 * Go pins all borrowed storage until completion and waits before reusing it. */
typedef struct wg_read_packet {
    uint8_t *data;
    uint32_t capacity;
    uint32_t size;
    wg_endpoint source;
} wg_read_packet;
typedef int32_t (*wg_read_fn)(void *, wg_read_packet *, uint32_t, uintptr_t);
typedef int32_t (*wg_write_link_async_fn)(void *, const wg_packet *, uint32_t,
    const wg_endpoint *, uintptr_t);
typedef int32_t (*wg_write_tun_async_fn)(void *, const wg_packet *, uint32_t, uintptr_t);

/* Go -> host: transmit 1..WG_IO_MAX_BATCH UDP datagrams to one destination.
 * Return zero once the entire batch is copied/accepted, without partial writes;
 * nonzero on failure. The callback may run concurrently on Go worker threads.
 * packets, payloads and destination are borrowed only until return. Copy if queued.
 * It must return promptly and must not call back into the WireGuard API or
 * wait for the host's lifecycle thread. No packet delivery is implied by zero.
 * Empty datagrams have size zero and may have a null packet pointer. */
typedef int32_t (*wg_write_link_fn)(void *context,
    const wg_packet *packets, uint32_t count, const wg_endpoint *destination);

/* Copied at startup. The context is host-owned and must remain valid through
 * wgTurnOffWithPassiveIO (and until host reads are detached). Go never opens
 * or closes the host socket. local_port must be the actual, nonzero bound port; listen_port must
 * be zero or match it. Port changes require a host-controlled device restart.
 * Nonzero fwmarks are unsupported; apply routing/protection in the host. */
typedef struct wg_passive_link {
    uint16_t local_port;
    wg_write_link_fn write;
    /* Optional borrowed I/O; null retains the copying ingress/write API. */
    wg_read_fn read;
    wg_write_link_async_fn write_async;
} wg_passive_link;

/* Go -> host: write 1..WG_IO_MAX_BATCH decrypted raw IP packets to the tunnel.
 * Same all-or-nothing acceptance, lifetime,
 * concurrency and non-reentrancy requirements as wg_write_link_fn. No AF or
 * virtio header is included; the host handles platform framing. */
typedef int32_t (*wg_write_tun_fn)(void *context, const wg_packet *packets, uint32_t count);

/* Copied at startup. MTU is fixed for this device lifetime (1..65535).
 * Host interface/MTU changes require restarting the device. Go owns no TUN fd
 * and emits no interface events: passive startup/shutdown control its lifetime. */
typedef struct wg_passive_tun {
    uint32_t mtu;
    wg_write_tun_fn write;
    /* Optional borrowed I/O; null retains the copying ingress/write API. */
    wg_read_fn read;
    wg_write_tun_async_fn write_async;
} wg_passive_tun;

static inline int32_t wg_passive_link_write(
    wg_write_link_fn write, void *context,
    const wg_packet *packets, uint32_t count,
    const wg_endpoint *destination
) {
    return write(context, packets, count, destination);
}

static inline int32_t wg_passive_tun_write(
    wg_write_tun_fn write, void *context,
    const wg_packet *packets, uint32_t count
) {
    return write(context, packets, count);
}

static inline int32_t wg_passive_read(wg_read_fn read, void *context,
    wg_read_packet *packets, uint32_t count, uintptr_t request) {
    return read(context, packets, count, request);
}
static inline int32_t wg_passive_link_write_async(wg_write_link_async_fn write,
    void *context, const wg_packet *packets, uint32_t count,
    const wg_endpoint *destination, uintptr_t request) {
    return write(context, packets, count, destination, request);
}
static inline int32_t wg_passive_tun_write_async(wg_write_tun_async_fn write,
    void *context, const wg_packet *packets, uint32_t count, uintptr_t request) {
    return write(context, packets, count, request);
}
