// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __winrt_loop_struct *winrt_loop;
/* Runtime boundary. No WinRT socket or TUN objects cross this interface.
 * Addresses have the same layout as pp_socket_address. */
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} winrt_address;
enum { WinrtEOF = 1 };
typedef bool (*winrt_receive)(void *, const uint8_t *, size_t,
    const winrt_address *, int32_t);

/* Owned transport capability, shared by daemon and passive consumers.
 * subscribe(NULL) drains borrowed callback contexts. Writes copy before return.
 * Lifecycle and writes are owner-serialized; receive callbacks must not reenter.
 * Callbacks run on native producers and only enqueue daemon messages or feed the passive adapter. */
typedef struct winrt_transport winrt_transport;
struct winrt_transport {
    void *context;
    void (*release)(void *);
    bool (*subscribe)(void *, winrt_receive, void *);
    bool (*resume)(void *);
    void (*stop)(void *);
    int32_t (*write)(void *, const uint8_t *, size_t, const winrt_address *);
    bool (*local_address)(void *, winrt_address *);
    bool unconnected;
};

typedef bool (*winrt_configure)(void *, uintptr_t);
typedef struct {
    bool tcp;
    bool unconnected;
    bool dual_stack;
    int timeout_ms;
    winrt_configure configure;
    void *context;
} winrt_connect_options;
/* Creates, configures and opens a link in one operation. configure receives a
 * temporary native policy token; it must not retain or dereference that token.
 * A null loop reuses the current submitted worker, or creates a standalone loop
 * when called outside submitted work. The returned transport retains its loop. */
winrt_transport *winrt_connect(winrt_loop, const char *host, uint16_t port,
    const winrt_connect_options *options);

winrt_loop winrt_loop_create(void);
/* Accepted work executes once on the persistent worker. Its socket factory
 * reuses that same runtime; free drains accepted work before releasing it. */
bool winrt_loop_submit(winrt_loop, void (*execute)(void *), void *context);
void winrt_loop_free(winrt_loop);
#ifdef __cplusplus
}
#endif
