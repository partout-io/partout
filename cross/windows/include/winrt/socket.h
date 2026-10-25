// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The available protocols. */
typedef enum { WinrtSocketProtoTCP, WinrtSocketProtoUDP } winrt_socket_proto;

/* The opaque socket type. */
typedef struct __winrt_socket_struct *winrt_socket;

typedef struct {
    bool dual_stack;
    int timeout_ms;
} winrt_socket_open_options;

/* Numeric endpoint. family is 4 or 6; port and scope_id are host endian. */
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} winrt_socket_address;

/* Worker-thread callbacks are serialized per socket. Buffers and source are
 * borrowed until return; only unconnected UDP supplies source. Error is zero
 * for data, 1 for TCP EOF, otherwise an HRESULT. False pauses packet delivery.
 * Register on attach, clear on detach; replacing a callback is rejected.
 * Clearing drains callbacks. Callbacks must not reenter socket APIs. Keep context
 * alive until cleared. TCP delivers stream chunks, without application framing. */
typedef bool (*winrt_socket_on_receive)(void *context, const uint8_t *bytes,
    size_t length, const winrt_socket_address *source, int32_t error);

/* Close the owned socket and free the wrapper after all callers have returned. */
void winrt_socket_free(winrt_socket socket);

/* Create the transport before configuring and opening it. */
winrt_socket winrt_socket_create(winrt_socket_proto proto, bool unconnected);

/* Configure the transport before calling open. Connected opens are bounded by
 * timeout_ms; unconnected UDP binds a numeric local endpoint. */
bool winrt_socket_open(winrt_socket socket, const char *host, uint16_t port,
    const winrt_socket_open_options *options);

bool winrt_socket_set_on_receive(winrt_socket socket, winrt_socket_on_receive callback, void *context);

/* Resume paused delivery without restoring a cleared callback. */
bool winrt_socket_resume_reading(winrt_socket socket);

/* Synchronous completion of WriteAsync; writes one whole datagram or all stream
 * bytes. Callers serialize writes with other writes, open/configuration and free.
 * StopWrites and receive callback management may overlap a write.
 * Returns zero or HRESULT. Unconnected UDP needs destination. */
int32_t winrt_socket_write(winrt_socket socket, const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination);

/* Reject queued/future writes with E_ABORT; an already admitted write may finish. */
void winrt_socket_stop_writes(winrt_socket socket);

/* Returns the bound/connected local endpoint, including the assigned local port. */
bool winrt_socket_get_address(winrt_socket socket, winrt_socket_address *address);

#ifdef __cplusplus
}
#endif
