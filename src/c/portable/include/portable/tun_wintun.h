/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */
#pragma once

#include <winsock2.h>
#include <Windows.h>
#include <wintun.h>

/* Private handle shared by the controller creator and core packet I/O.
 * Each handle retains the DLL functions needed to use and release it. */
struct __partout_tun_struct {
    HMODULE library;
    WINTUN_ADAPTER_HANDLE adapter;
    WINTUN_SESSION_HANDLE session;
    WINTUN_CLOSE_ADAPTER_FUNC *close_adapter;
    WINTUN_END_SESSION_FUNC *end_session;
    WINTUN_GET_READ_WAIT_EVENT_FUNC *get_read_wait_event;
    WINTUN_RECEIVE_PACKET_FUNC *receive_packet;
    WINTUN_RELEASE_RECEIVE_PACKET_FUNC *release_receive_packet;
    WINTUN_ALLOCATE_SEND_PACKET_FUNC *allocate_send_packet;
    WINTUN_SEND_PACKET_FUNC *send_packet;
};
