/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
#include <assert.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>
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

int main(void) {
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
