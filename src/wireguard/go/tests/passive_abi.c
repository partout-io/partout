/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
#include <assert.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <wg_go/wg_go.h>

_Static_assert(sizeof(wg_endpoint) == 24, "endpoint ABI size");
_Static_assert(offsetof(wg_endpoint, scope_id) == 16, "scope offset");
_Static_assert(offsetof(wg_endpoint, port) == 20, "port offset");
_Static_assert(offsetof(wg_endpoint, family) == 22, "family offset");

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
    wg_passive_link link = {.local_port = 51820, .read = borrow_link, .write = borrow_write};
    wg_passive_tun tun = {.mtu = 1400, .read = borrow_tun, .write = borrow_write_tun};
    assert(wgTurnOnWithPassiveIO(NULL, &link, &tun, &p) == -1);
    assert(wgTurnOnWithPassiveIO("", &link, NULL, &p) == -1);
    wg_passive_link invalid_link = link;
    invalid_link.read = NULL;
    assert(wgTurnOnWithPassiveIO("", &invalid_link, &tun, &p) == -1);
    invalid_link = link;
    invalid_link.write = NULL;
    assert(wgTurnOnWithPassiveIO("", &invalid_link, &tun, &p) == -1);
    wg_passive_tun invalid_tun = tun;
    invalid_tun.read = NULL;
    assert(wgTurnOnWithPassiveIO("", &link, &invalid_tun, &p) == -1);
    invalid_tun = tun;
    invalid_tun.write = NULL;
    assert(wgTurnOnWithPassiveIO("", &link, &invalid_tun, &p) == -1);
    // Failed startup must not leave host requests waiting for a looper.
    assert(wgTurnOnWithPassiveIO("listen_port=1234\n", &link, &tun, &p) == -1);
    assert(p.read_requests[0] == 0 && p.read_requests[1] == 0 && p.write_request == 0);
    int32_t handle = wgTurnOnWithPassiveIO(
        "private_key=0101010101010101010101010101010101010101010101010101010101010101\n"
        "public_key=0900000000000000000000000000000000000000000000000000000000000000\n"
        "endpoint=127.0.0.1:51821\nallowed_ip=10.0.0.2/32\n", &link, &tun, &p);
    assert(handle >= 0);
    char *config = wgGetConfigWithPassiveIO(handle);
    assert(config != NULL && strstr(config, "listen_port=51820") != NULL);
    free(config);
    wgDisableRoamingWithPassiveIO(handle);
    assert(wgGetConfig(handle) == NULL);
    wgTurnOff(handle); // Passive and native registries are isolated.
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


typedef struct startup_probe {
    borrowed_probe io;
    int32_t handle;
} startup_probe;
static void *start_keepalive(void *raw) {
    startup_probe *p = raw;
    wg_passive_link link = {.local_port = 51820, .read = borrow_link, .write = borrow_write};
    wg_passive_tun tun = {.mtu = 1400, .read = borrow_tun, .write = borrow_write_tun};
    p->handle = wgTurnOnWithPassiveIO(
        "private_key=0101010101010101010101010101010101010101010101010101010101010101\n"
        "public_key=0900000000000000000000000000000000000000000000000000000000000000\n"
        "endpoint=127.0.0.1:51821\npersistent_keepalive_interval=25\n", &link, &tun, &p->io);
    return NULL;
}
static void test_keepalive_startup(int cancel) {
    startup_probe p = {.io = {.mutex = PTHREAD_MUTEX_INITIALIZER}, .handle = -1};
    pthread_t worker;
    assert(pthread_create(&worker, NULL, start_keepalive, &p) == 0);
    uintptr_t request = 0;
    for (int i = 0; i < 3000 && !request; ++i) {
        pthread_mutex_lock(&p.io.mutex);
        request = p.io.write_request;
        pthread_mutex_unlock(&p.io.mutex);
        if (!request) usleep(1000);
    }
    assert(request != 0); // Up must publish its handshake before returning.
    pthread_mutex_lock(&p.io.mutex);
    assert(p.io.writes[0].size == 148 && p.io.writes[0].data[0] == 1);
    if (cancel) p.io.closing = 1;
    pthread_mutex_unlock(&p.io.mutex);
    wgCompleteIO(request, cancel ? 0 : 1, cancel ? WG_IO_CLOSED : WG_IO_OK);
    assert(pthread_join(worker, NULL) == 0);
    assert(p.handle >= 0);
    char *config = wgGetConfigWithPassiveIO(p.handle);
    assert(config && strstr(config, "persistent_keepalive_interval=25"));
    free(config);
    pthread_mutex_lock(&p.io.mutex);
    p.io.closing = 1;
    uintptr_t reads[2] = {p.io.read_requests[0], p.io.read_requests[1]};
    pthread_mutex_unlock(&p.io.mutex);
    for (unsigned i = 0; i < 2; ++i) if (reads[i]) wgCompleteIO(reads[i], 0, WG_IO_CLOSED);
    wgTurnOffWithPassiveIO(p.handle);
    pthread_mutex_destroy(&p.io.mutex);
}

/* Direct nonblocking callbacks run on Go workers, complete inline, and never
 * retain borrowed storage. AGAIN is retried by Go, including before TUN commit. */
typedef struct direct_probe {
    pthread_mutex_t mutex;
    unsigned link_reads, tun_reads, writes, packets;
    int committed;
} direct_probe;
static int32_t direct_link_read(void *raw, wg_read_packet *packets, uint32_t count, uintptr_t request) {
    direct_probe *p = raw;
    assert(packets && count && request);
    pthread_mutex_lock(&p->mutex);
    ++p->link_reads;
    pthread_mutex_unlock(&p->mutex);
    usleep(100000); /* Emulate the native host readiness wait. */
    wgCompleteIO(request, 0, WG_IO_AGAIN);
    return WG_IO_OK;
}
static int32_t direct_tun_read(void *raw, wg_read_packet *packets, uint32_t count, uintptr_t request) {
    direct_probe *p = raw;
    assert(packets && count && request);
    pthread_mutex_lock(&p->mutex);
    ++p->tun_reads;
    int available = p->committed && !p->packets;
    if (available) {
        assert(packets[0].capacity >= 20);
        memset(packets[0].data, 0, 20);
        packets[0].data[0] = 0x45; packets[0].data[3] = 20;
        packets[0].data[12] = packets[0].data[16] = 10;
        packets[0].data[15] = 1; packets[0].data[19] = 2;
        packets[0].size = 20;
        ++p->packets;
    }
    pthread_mutex_unlock(&p->mutex);
    if (!available) usleep(100000);
    wgCompleteIO(request, available ? 1 : 0, available ? WG_IO_OK : WG_IO_AGAIN);
    return WG_IO_OK;
}
static int32_t direct_link_write(void *raw, const wg_packet *packets, uint32_t count,
    const wg_endpoint *destination, uintptr_t request) {
    direct_probe *p = raw;
    assert(packets && count && request && destination && destination->family == 4);
    pthread_mutex_lock(&p->mutex);
    int blocked = ++p->writes == 1;
    pthread_mutex_unlock(&p->mutex);
    wgCompleteIO(request, blocked ? 0 : count, blocked ? WG_IO_AGAIN : WG_IO_OK);
    return WG_IO_OK;
}
static void test_direct_io(void) {
    direct_probe p = {.mutex = PTHREAD_MUTEX_INITIALIZER};
    wg_passive_link link = {.local_port = 51820, .read = direct_link_read, .write = direct_link_write};
    wg_passive_tun tun = {.mtu = 1400, .read = direct_tun_read, .write = borrow_write_tun};
    int32_t handle = wgTurnOnWithPassiveIO(
        "private_key=0101010101010101010101010101010101010101010101010101010101010101\n"
        "public_key=0900000000000000000000000000000000000000000000000000000000000000\n"
        "endpoint=127.0.0.1:51821\nallowed_ip=10.0.0.0/24\npersistent_keepalive_interval=25\n",
        &link, &tun, &p);
    assert(handle >= 0);
    int ready = 0;
    for (int i = 0; i < 3000 && !ready; ++i) {
        pthread_mutex_lock(&p.mutex);
        ready = p.link_reads >= 2 && p.tun_reads >= 2 && p.writes >= 2;
        pthread_mutex_unlock(&p.mutex);
        if (!ready) usleep(1000);
    }
    assert(ready);
    pthread_mutex_lock(&p.mutex);
    p.committed = 1;
    pthread_mutex_unlock(&p.mutex);
    int received = 0;
    for (int i = 0; i < 3000 && !received; ++i) {
        pthread_mutex_lock(&p.mutex);
        received = p.packets == 1;
        pthread_mutex_unlock(&p.mutex);
        if (!received) usleep(1000);
    }
    assert(received);
    /* No native admission queue to drain: shutdown cancels retries after the native wait. */
    wgTurnOffWithPassiveIO(handle);
    pthread_mutex_destroy(&p.mutex);
}

int main(void) {
    test_direct_io();
    test_borrowed_io();
    test_keepalive_startup(0);
    test_keepalive_startup(1);
    return 0;
}
