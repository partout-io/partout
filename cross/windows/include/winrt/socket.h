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
    bool dual_stack;
    int timeout_ms;
} winrt_socket_open_options;

winrt_socket winrt_socket_create(winrt_socket_proto proto, bool unconnected);
void winrt_socket_free(winrt_socket socket);
/* Configure the transport before calling open. Connected opens are bounded by
 * timeout_ms; unconnected UDP binds a numeric local endpoint. */
bool winrt_socket_open(winrt_socket socket, const char *host, uint16_t port,
    const winrt_socket_open_options *options);
/* Returns the bound/connected local endpoint, including the assigned local port. */
bool winrt_socket_get_address(winrt_socket socket, winrt_socket_address *address);
/* Worker-thread callbacks are serialized per socket. Buffers and source are
 * borrowed until return; only unconnected UDP supplies source. Error is zero
 * for data, 1 for TCP EOF, otherwise an HRESULT. False pauses packet delivery.
 * Register on attach, clear on detach; replacing a callback is rejected.
 * Clearing drains callbacks. Callbacks must not reenter socket APIs. Keep context
 * alive until cleared. TCP delivers stream chunks, without application framing. */
typedef bool (*winrt_socket_on_receive)(void *context, const uint8_t *bytes,
    size_t length, const winrt_socket_address *source, int32_t error);
bool winrt_socket_set_on_receive(winrt_socket socket, winrt_socket_on_receive callback, void *context);
bool winrt_socket_resume_reading(winrt_socket socket);
/* Serialized synchronous completion of WriteAsync; writes one whole datagram
 * or all stream bytes. Returns zero or HRESULT. Unconnected UDP needs destination. */
int32_t winrt_socket_write(winrt_socket socket, const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination);
/* Reject queued/future writes with E_ABORT; an already admitted write may finish. */
void winrt_socket_stop_writes(winrt_socket socket);
#ifdef __cplusplus
}
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <functional>
// Borrow the transport for VPN channel association; no socket internals escape.
winrt::Windows::Foundation::IInspectable winrt_socket_transport(winrt_socket socket);
bool winrt_socket_is_unconnected(winrt_socket socket);
// Before open: constrain independent UDP to the selected physical adapter.
void winrt_socket_set_adapter(winrt_socket socket,
    winrt::Windows::Networking::Connectivity::NetworkAdapter const &adapter);
// Retains callback state, not the socket wrapper. Safe after link detach.
std::function<void(const uint8_t *, size_t)> winrt_socket_channel_receiver(winrt_socket socket);
// Stop/drain direct reads before StartWithMainTransport takes receive ownership.
void winrt_socket_take_over(winrt_socket socket);
// After channel startup, send encapsulated packets through its send-buffer pool.
void winrt_socket_set_channel_writer(winrt_socket socket,
    std::function<int32_t(const uint8_t *, size_t)> writer);
#endif
