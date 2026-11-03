// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
namespace Partout {
class RuntimeLoop;
}

typedef Partout::RuntimeLoop *winrt_loop;
extern "C" {
#else
typedef struct __winrt_loop_struct *winrt_loop;
#endif

/* Native I/O C ABI. No WinRT socket or TUN objects cross this interface.
 * Addresses have the same layout as pp_socket_address. */
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} winrt_address;

enum {
    WinrtEOF = 1
};

enum { WinrtMaxBatch = 256 };
typedef struct {
    const uint8_t *data;
    size_t size;
} winrt_packet;
typedef bool (*winrt_receive_batch)(void *, const winrt_packet *, size_t, const winrt_address *, int32_t);

typedef bool (*winrt_receive)(void *, const uint8_t *, size_t, const winrt_address *, int32_t);

/* Owned transport capability, shared by daemon and passive consumers.
 * subscribe(NULL) drains borrowed callback contexts. Writes borrow input until
 * return: channel output copies directly into VpnChannel's pool; independent
 * socket output retains a WinRT Buffer until asynchronous completion. Writes
 * execute on the producer without per-packet apartment initialization.
 * release drains callbacks immediately; native destruction may be deferred.
 * Lifecycle and writes are owner-serialized. Receive callbacks may submit output
 * but must defer lifecycle changes (including callback removal and release).
 * Callbacks run on native producers: serialized OpenVPN execution, owned queue
 * fallback under contention, or WireGuard's passive adapter.
 */
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
    /* Optional capabilities. Packet views expire at return. Batch write reports
     * the accepted prefix even on error; packets remain separate datagrams.
     * count must be 1..WinrtMaxBatch. Rebuild both sides when changing this ABI. */
    int32_t (*write_batch)(void *, const winrt_packet *, size_t, const winrt_address *, size_t *);
    bool (*subscribe_batch)(void *, winrt_receive_batch, void *);
};

typedef bool (*winrt_configure)(void *, uintptr_t);

typedef struct {
    bool tcp;
    bool unconnected;
    /* Optional capabilities. Packet views expire at return. Batch write reports
     * the accepted prefix even on error; packets remain separate datagrams.
     * count must be 1..WinrtMaxBatch. Rebuild both sides when changing this ABI. */
    int32_t (*write_batch)(void *, const winrt_packet *, size_t, const winrt_address *, size_t *);
    bool (*subscribe_batch)(void *, winrt_receive_batch, void *);
    bool dual_stack;
    int timeout_ms;
    winrt_configure configure;
    void *context;
} winrt_connect_options;

/* Creates, configures and opens a link in one operation. configure receives a
 * temporary native policy token; it must not retain or dereference that token.
 * Borrows the active runtime's loop; fails if no runtime is active. The owner
 * must outlive all transports and drain their queued destruction. */
winrt_transport *winrt_connect(const char *host, uint16_t port,
                               const winrt_connect_options *options);

/* Explicit owner API for standalone native consumers and tests. Only one loop
 * may be active. VpnChannelRuntime owns its loop directly in C++.
 * Before free: stop producers, drain preparation, release every transport and
 * drain teardown. Never free a borrowed handle or free on the worker itself. */
winrt_loop winrt_loop_create(void);
void winrt_loop_free(winrt_loop);
/* Borrowed lookup: the runtime owner must outlive every user of this handle. */
winrt_loop winrt_loop_current(void);
/* Accepted work executes once on the runtime worker. Drain is a barrier for
 * previously submitted commands; callers must first quiesce their producers. */
bool winrt_loop_submit(winrt_loop, void (*execute)(void *), void *context);
void winrt_loop_drain(winrt_loop);
#ifdef __cplusplus
}
#endif
