/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include <stddef.h>
#include <stdint.h>

/* MSVC does not support Clang's nullability annotations. */
#if defined(_MSC_VER) && !defined(__clang__)
#pragma warning(push)
#pragma warning(disable: 4068)
#pragma push_macro("_Nullable")
#pragma push_macro("_Nonnull")
#define _Nullable
#define _Nonnull
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include "portable/socket.h"

typedef struct pp_winrt_socket *pp_winrt_socket_ref;
enum { PPWinRTFailure = -1, PPWinRTWouldBlock = -2 };
/* The bridge initializes WinRT on calling threads. Calls on one handle must be
 * serialized. open starts connecting; poll returns 0 when connected.
 * tcp is 0 for UDP, 1 for TCP. timeout_ms <= 0 disables the connect deadline.
 * capacity bounds buffered input and each accepted write.
 * configure is invoked synchronously after creation and before ConnectAsync.
 * Its fd argument encodes the pp_winrt_socket pointer, not a Winsock SOCKET.
 * Returning false closes the socket and aborts open. Callback arguments are
 * borrowed only for the duration of the callback. */
pp_winrt_socket_ref pp_winrt_socket_open(const char *host, uint16_t port,
    int tcp, int timeout_ms, size_t capacity, int32_t *error,
    const pp_reachability *reachability, pp_socket_configure configure, void *configure_ctx);
int pp_winrt_socket_poll(pp_winrt_socket_ref socket);
/* read returns bytes, WouldBlock, or Failure. Zero means TCP EOF (or an empty
 * UDP datagram). UDP boundaries are preserved; an undersized buffer fails
 * without consuming the datagram. */
int pp_winrt_socket_read(pp_winrt_socket_ref socket, uint8_t *dst, size_t size);
/* Copies data before returning; a positive result means accepted, not sent.
 * Only one write is in flight. Subsequent calls/poll observe async errors. */
int pp_winrt_socket_write(pp_winrt_socket_ref socket, const uint8_t *src, size_t size);
int32_t pp_winrt_socket_error(pp_winrt_socket_ref socket);
/* Borrowed Windows event HANDLE, valid until close. No socket handle is exposed. */
void *pp_winrt_socket_watch_handle(pp_winrt_socket_ref socket);
int pp_winrt_socket_set_event_mask(pp_winrt_socket_ref socket, int read, int write);
int pp_winrt_socket_reset_events(pp_winrt_socket_ref socket);
/* Cancels pending operations and releases the handle. */
void pp_winrt_socket_close(pp_winrt_socket_ref socket);
/* Borrowed IInspectable-compatible ABI pointer; valid until socket closes. */
void *pp_winrt_socket_get_transport(const struct pp_winrt_socket *socket);

#ifdef __cplusplus
}
#endif

#if defined(_MSC_VER) && !defined(__clang__)
#pragma pop_macro("_Nonnull")
#pragma pop_macro("_Nullable")
#pragma warning(pop)
#endif
