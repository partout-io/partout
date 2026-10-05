/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
#include <assert.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>
#include <pthread.h>
#include <wg_go/wg_go.h>

_Static_assert(sizeof(wg_endpoint) == 24, "endpoint ABI size");
_Static_assert(offsetof(wg_endpoint, scope_id) == 16, "scope offset");
_Static_assert(offsetof(wg_endpoint, port) == 20, "port offset");
_Static_assert(offsetof(wg_endpoint, family) == 22, "family offset");

typedef struct output_probe {
    atomic_uint calls;
} output_probe;

static int32_t write_link(void *context, const wg_packet *packets,
        uint32_t count, const wg_endpoint *destination) {
    if (context != NULL) {
        assert(count > 0 && count <= WG_IO_MAX_BATCH);
        assert(destination->family == 4 && destination->port == 51821);
        for (uint32_t i = 0; i < count; ++i) {
            assert(packets[i].data != NULL && packets[i].size == 148);
            assert(packets[i].data[0] == 1); // Handshake initiation.
        }
        atomic_fetch_add(&((output_probe *)context)->calls, 1);
        return WG_IO_OK;
    }
    assert(0 && "invalid startup must not transmit");
    return -1;
}

static int32_t write_tun(void *context, const wg_packet *packets, uint32_t count) {
    (void)context; (void)packets; (void)count;
    assert(0 && "no peer can deliver decrypted data");
    return -1;
}

/* Retain real Go buffers after callback return, then complete/cancel them.
 * This exercises pinning, worker waits, and the shutdown admission barrier. */
typedef struct borrowed_probe {
    pthread_mutex_t mutex;
    int closing;
    wg_read_packet *reads[2];
    uintptr_t read_requests[2];
    const wg_packet *writes;
    uint32_t write_count;
    uintptr_t write_request;
} borrowed_probe;

static int32_t borrow_read(borrowed_probe *p, unsigned side,
        wg_read_packet *packets, uint32_t count, uintptr_t request) {
    assert(count > 0 && count <= WG_IO_MAX_BATCH && request != 0);
    pthread_mutex_lock(&p->mutex);
    if (p->closing) { pthread_mutex_unlock(&p->mutex); return WG_IO_CLOSED; }
    assert(p->read_requests[side] == 0);
    p->reads[side] = packets;
    p->read_requests[side] = request;
    pthread_mutex_unlock(&p->mutex);
    return WG_IO_OK;
}
static int32_t borrow_link(void *p, wg_read_packet *packets, uint32_t n, uintptr_t r) {
    return borrow_read(p, 0, packets, n, r);
}
static int32_t borrow_tun(void *p, wg_read_packet *packets, uint32_t n, uintptr_t r) {
    return borrow_read(p, 1, packets, n, r);
}
static int32_t borrow_write(void *context, const wg_packet *packets,
        uint32_t count, const wg_endpoint *destination, uintptr_t request) {
    borrowed_probe *p = context;
    assert(destination->port == 51821);
    pthread_mutex_lock(&p->mutex);
    if (p->closing || p->write_request) { pthread_mutex_unlock(&p->mutex); return WG_IO_CLOSED; }
    p->writes = packets;
    p->write_count = count;
    p->write_request = request;
    pthread_mutex_unlock(&p->mutex);
    return WG_IO_OK;
}
static int32_t borrow_write_tun(void *p, const wg_packet *packets, uint32_t n, uintptr_t r) {
    (void)p; (void)packets; (void)n;
    // Completion before submission returns is legal too.
    wgCompleteIO(r, n, WG_IO_OK);
    return WG_IO_OK;
}
static void test_borrowed_io(void) {
    borrowed_probe p = {.mutex = PTHREAD_MUTEX_INITIALIZER};
    wg_passive_link link = {.local_port = 51820, .read = borrow_link, .write_async = borrow_write};
    wg_passive_tun tun = {.mtu = 1400, .read = borrow_tun, .write_async = borrow_write_tun};
    // Failed startup must not leave host requests waiting for a looper.
    assert(wgTurnOnWithPassiveIO("listen_port=1234\n", &link, &tun, &p) == -1);
    assert(p.read_requests[0] == 0 && p.read_requests[1] == 0 && p.write_request == 0);
    int32_t handle = wgTurnOnWithPassiveIO(
        "private_key=0101010101010101010101010101010101010101010101010101010101010101\n"
        "public_key=0900000000000000000000000000000000000000000000000000000000000000\n"
        "endpoint=127.0.0.1:51821\nallowed_ip=10.0.0.2/32\n", &link, &tun, &p);
    assert(handle >= 0);
    uintptr_t input = 0;
    for (int i = 0; i < 3000 && !input; ++i) {
        pthread_mutex_lock(&p.mutex);
        if (p.read_requests[1]) {
            input = p.read_requests[1];
            wg_read_packet *packet = &p.reads[1][0];
            assert(packet->capacity >= 20);
            memset(packet->data, 0, 20);
            packet->data[0] = 0x45; packet->data[3] = 20;
            packet->data[12] = packet->data[16] = 10;
            packet->data[15] = 1; packet->data[19] = 2;
            packet->size = 20;
            p.read_requests[1] = 0;
        }
        pthread_mutex_unlock(&p.mutex);
        if (!input) usleep(1000);
    }
    assert(input != 0);
    wgCompleteIO(input, 1, WG_IO_OK);
    uintptr_t output = 0;
    for (int i = 0; i < 3000 && !output; ++i) {
        pthread_mutex_lock(&p.mutex);
        output = p.write_request;
        pthread_mutex_unlock(&p.mutex);
        if (!output) usleep(1000);
    }
    assert(output != 0);
    pthread_mutex_lock(&p.mutex);
    assert(p.write_count > 0 && p.writes[0].size == 148 && p.writes[0].data[0] == 1);
    p.closing = 1;
    uintptr_t reads[2] = {p.read_requests[0], p.read_requests[1]};
    pthread_mutex_unlock(&p.mutex);
    // Quiesce reads, cancel writes, then join Go. Never return storage earlier.
    for (unsigned i = 0; i < 2; ++i) if (reads[i]) wgCompleteIO(reads[i], 0, WG_IO_CLOSED);
    wgCompleteIO(output, 0, WG_IO_CLOSED);
    wgTurnOffWithPassiveIO(handle);
    pthread_mutex_destroy(&p.mutex);
}

int main(void) {
    test_borrowed_io();
    wg_endpoint source = {.address = {127, 0, 0, 1}, .port = 51820, .family = 4};
    wg_passive_link link = {.local_port = 51820, .write = write_link};
    wg_passive_tun tun = {.mtu = 1400, .write = write_tun};
    assert(wgTurnOnWithPassiveIO(NULL, &link, &tun, NULL) == -1);
    assert(wgTurnOnWithPassiveIO("", &link, NULL, NULL) == -1);
    uint8_t packet[] = {0x45, 0, 0, 20};
    wg_packet packets[] = {{packet, sizeof(packet)}, {packet, sizeof(packet)}};
    wg_endpoint sources[] = {source, source};
    assert(wgReceiveDatagrams(-1, NULL, NULL, 0) == WG_IO_OK);
    assert(wgReceiveTunPackets(-1, NULL, 0) == WG_IO_OK);
    assert(wgReceiveDatagrams(-1, NULL, sources, 1) == WG_IO_INVALID);
    assert(wgReceiveDatagrams(-1, packets, NULL, 1) == WG_IO_INVALID);
    assert(wgReceiveTunPackets(-1, NULL, 1) == WG_IO_INVALID);
    assert(wgReceiveTunPackets(-1, packets, WG_IO_MAX_BATCH + 1) == WG_IO_INVALID);
    assert(wgReceiveDatagrams(-1, packets, sources, WG_IO_MAX_BATCH + 1) == WG_IO_INVALID);
    assert(wgReceiveDatagrams(-1, packets, sources, 2) == WG_IO_CLOSED);
    assert(wgReceiveTunPackets(-1, packets, 2) == WG_IO_CLOSED);
    const int32_t handle = wgTurnOnWithPassiveIO("", &link, &tun, NULL);
    assert(handle >= 0);
    assert(wgReceiveDatagrams(handle, packets, sources, 2) == WG_IO_OK);
    assert(wgReceiveTunPackets(handle, packets, 2) == WG_IO_OK);
    packets[1].data = NULL;
    assert(wgReceiveDatagrams(handle, packets, sources, 2) == WG_IO_INVALID);
    assert(wgReceiveTunPackets(handle, packets, 2) == WG_IO_INVALID);
    packets[1].data = packet;
    sources[1].family = 0;
    assert(wgReceiveDatagrams(handle, packets, sources, 2) == WG_IO_INVALID);
    sources[1] = source;
    packets[1].size = 0;
    assert(wgReceiveDatagrams(handle, packets, sources, 2) == WG_IO_OK);
    assert(wgReceiveTunPackets(handle, packets, 2) == WG_IO_INVALID);
    packets[1].size = sizeof(packet);
    char *config = wgGetConfigWithPassiveIO(handle);
    assert(config != NULL && strstr(config, "listen_port=51820") != NULL);
    free(config);
    wgDisableRoamingWithPassiveIO(handle);
    assert(wgGetConfig(handle) == NULL);
    wgTurnOff(handle); // The native registry has no device with this ID.
    assert(wgReceiveTunPackets(handle, packets, 1) == WG_IO_OK);
    wgTurnOffWithPassiveIO(handle);
    assert(wgReceiveDatagrams(handle, packets, sources, 2) == WG_IO_CLOSED);
    assert(wgReceiveTunPackets(handle, packets, 2) == WG_IO_CLOSED);
    assert(wgGetConfigWithPassiveIO(handle) == NULL);
    const int32_t replacement = wgTurnOnWithPassiveIO("", &link, &tun, NULL);
    assert(replacement >= 0 && replacement != handle);
    wgTurnOffWithPassiveIO(handle);
    assert(wgReceiveTunPackets(replacement, packets, 1) == WG_IO_OK);
    wgTurnOffWithPassiveIO(replacement);

    // Exercise a real Go -> C callback with pinned Go payload pointers.
    output_probe probe = {0};
    const int32_t outbound = wgTurnOnWithPassiveIO(
        "private_key=0101010101010101010101010101010101010101010101010101010101010101\n"
        "public_key=0900000000000000000000000000000000000000000000000000000000000000\n"
        "endpoint=127.0.0.1:51821\nallowed_ip=10.0.0.2/32\n",
        &link, &tun, &probe);
    assert(outbound >= 0);
    uint8_t ip[20] = {0x45, 0, 0, 20};
    ip[12] = ip[16] = 10;
    ip[15] = 1;
    ip[19] = 2;
    wg_packet input = {ip, sizeof(ip)};
    assert(wgReceiveTunPackets(outbound, &input, 1) == WG_IO_OK);
    for (int i = 0; i < 3000 && atomic_load(&probe.calls) == 0; ++i) usleep(1000);
    assert(atomic_load(&probe.calls) > 0);
    wgTurnOffWithPassiveIO(outbound);
    return 0;
}
