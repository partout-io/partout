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
    WG_IO_AGAIN = -3
};

/* Descriptors and payloads are borrowed until completion. */
typedef struct wg_packet {
    const uint8_t *data;
    uint32_t size;
} wg_packet;

/* Asynchronous borrowed I/O. Zero accepts the request and requires exactly one
 * wgCompleteIO(request, completed_count, status), possibly before return.
 * Nonzero rejects it and MUST NOT complete it. The host must release all
 * descriptors/payloads before completion. Cancellation completes with CLOSED.
 * Callbacks execute on Go workers and may complete inline. AGAIN completes a
 * processed prefix (zero for reads with no data); Go retries the remaining
 * packets after a cancellable wait. Before turn-off,
 * reject new requests and complete/cancel every accepted request.
 * Go pins all borrowed storage until completion and waits before reusing it. */
typedef struct wg_read_packet {
    uint8_t *data;
    uint32_t capacity;
    uint32_t size;
    wg_endpoint source;
} wg_read_packet;
typedef int32_t (*wg_read_fn)(void *context, wg_read_packet *packets,
    uint32_t count, uintptr_t request);
typedef int32_t (*wg_write_link_fn)(void *context, const wg_packet *packets,
    uint32_t count, const wg_endpoint *destination, uintptr_t request);
typedef int32_t (*wg_write_tun_fn)(void *context, const wg_packet *packets,
    uint32_t count, uintptr_t request);

/* Copied at startup; both callbacks are required and may run concurrently on
 * Go workers. Context remains host-owned through turn-off. local_port is the
 * actual nonzero bound port; listen_port must be zero or match it. Go never
 * opens/closes the socket. Port changes require a restart; nonzero marks are
 * unsupported. Empty UDP payloads may have null data pointers. */
typedef struct wg_passive_link {
    uint16_t local_port;
    wg_read_fn read;
    wg_write_link_fn write;
} wg_passive_link;

/* Required callbacks exchange raw IP packets, without AF or virtio headers.
 * MTU is fixed at startup (1..65535); changing it requires a restart. Go owns
 * no TUN descriptor and emits no interface events. */
typedef struct wg_passive_tun {
    uint32_t mtu;
    wg_read_fn read;
    wg_write_tun_fn write;
} wg_passive_tun;

/* cgo trampolines for host function pointers. */
static inline int32_t wg_passive_read(wg_read_fn read, void *context,
    wg_read_packet *packets, uint32_t count, uintptr_t request) {
    return read(context, packets, count, request);
}
static inline int32_t wg_passive_link_write(wg_write_link_fn write,
    void *context, const wg_packet *packets, uint32_t count,
    const wg_endpoint *destination, uintptr_t request) {
    return write(context, packets, count, destination, request);
}
static inline int32_t wg_passive_tun_write(wg_write_tun_fn write,
    void *context, const wg_packet *packets, uint32_t count, uintptr_t request) {
    return write(context, packets, count, request);
}
