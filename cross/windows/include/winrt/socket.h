// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct WinrtSocket *winrt_socket;
typedef enum { WinrtSocketProtoTCP, WinrtSocketProtoUDP } winrt_socket_proto;
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} winrt_socket_address;
typedef struct {
    bool unconnected;
    bool dual_stack;
    int timeout_ms;
} winrt_socket_open_options;

winrt_socket winrt_socket_create(winrt_socket_proto proto);
void winrt_socket_free(winrt_socket socket);
/* Configure the transport before calling open. Connected opens are bounded by
 * timeout_ms; unconnected UDP binds a numeric local endpoint. */
bool winrt_socket_open(winrt_socket socket, const char *host, uint16_t port,
    const winrt_socket_open_options *options);
/* Worker-thread callbacks are serialized per socket. Buffers and source are
 * borrowed until return; only unconnected UDP supplies source. Error is zero
 * for data, 1 for TCP EOF, otherwise an HRESULT. False pauses packet delivery.
 * Clearing drains callbacks and may be called reentrantly. Keep context alive
 * until cleared. TCP delivers stream chunks, without application framing. */
typedef bool (*winrt_socket_on_receive)(void *context, const uint8_t *bytes,
    size_t length, const winrt_socket_address *source, int32_t error);
bool winrt_socket_set_on_receive(winrt_socket socket, winrt_socket_on_receive callback, void *context);
bool winrt_socket_resume_reading(winrt_socket socket);
/* Failure delivery shares callback serialization, including while paused. */
void winrt_socket_notify_failure(winrt_socket socket, int32_t error);
/* Serialized synchronous completion of WriteAsync; writes one whole datagram
 * or all stream bytes. Returns zero or HRESULT. Unconnected UDP needs destination. */
int32_t winrt_socket_write(winrt_socket socket, const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination);
#ifdef __cplusplus
}
#include <winrt/Windows.Foundation.h>
// Borrow the transport for VPN channel association; no socket internals escape.
winrt::Windows::Foundation::IInspectable winrt_socket_transport(winrt_socket socket);
#endif
