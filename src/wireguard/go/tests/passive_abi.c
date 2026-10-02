/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
#include <assert.h>
#include <stddef.h>
#include <wg_go/wg_go.h>

_Static_assert(sizeof(wg_endpoint) == 24, "endpoint ABI size");
_Static_assert(offsetof(wg_endpoint, scope_id) == 16, "scope offset");
_Static_assert(offsetof(wg_endpoint, port) == 20, "port offset");
_Static_assert(offsetof(wg_endpoint, family) == 22, "family offset");

static int32_t write_link(void *context, const uint8_t *packet,
        uint32_t size, const wg_endpoint *destination) {
    (void)context; (void)packet; (void)size; (void)destination;
    assert(0 && "invalid startup must not transmit");
    return -1;
}

static int32_t write_tun(void *context, const uint8_t *packet, uint32_t size) {
    (void)context; (void)packet; (void)size;
    assert(0 && "no peer can deliver decrypted data");
    return -1;
}

int main(void) {
    wg_endpoint source = {.address = {127, 0, 0, 1}, .port = 51820, .family = 4};
    wg_passive_link link = {.local_port = 51820, .write = write_link};
    assert(wgReceiveDatagram(-1, NULL, 0, &source) == WG_IO_CLOSED);
    assert(wgReceiveDatagram(-1, NULL, 1, &source) == WG_IO_INVALID);
    assert(wgReceiveDatagram(-1, NULL, 0, NULL) == WG_IO_INVALID);
    wg_passive_tun tun = {.mtu = 1400, .write = write_tun};
    assert(wgTurnOnWithPassiveIO(NULL, &link, &tun, NULL) == -1);
    assert(wgTurnOnWithPassiveIO("", &link, NULL, NULL) == -1);
    uint8_t packet[] = {0x45, 0, 0, 20};
    assert(wgReceiveTunPacket(-1, packet, sizeof(packet)) == WG_IO_CLOSED);
    assert(wgReceiveTunPacket(-1, NULL, 1) == WG_IO_INVALID);
    assert(wgReceiveTunPacket(-1, packet, 0) == WG_IO_INVALID);
    const int32_t handle = wgTurnOnWithPassiveIO("", &link, &tun, NULL);
    assert(handle >= 0);
    assert(wgReceiveTunPacket(handle, packet, sizeof(packet)) == WG_IO_OK);
    wgTurnOff(handle);
    assert(wgReceiveTunPacket(handle, packet, sizeof(packet)) == WG_IO_CLOSED);
    return 0;
}
