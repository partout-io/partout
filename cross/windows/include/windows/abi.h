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

typedef Partout::RuntimeLoop *windows_loop;
extern "C" {
#else
typedef struct __windows_loop_struct *windows_loop;
#endif

/* Native I/O C ABI. No Windows socket or TUN objects cross this interface.
 * Addresses have the same layout as pp_socket_address. */
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} windows_address;

enum {
    WindowsEOF = 1
};

typedef bool (*windows_receive)(void *, const uint8_t *, size_t, const windows_address *, int32_t);

/* Owned transport capability, shared by daemon and passive consumers.
 * subscribe(NULL) drains borrowed callback contexts. Writes copy into a Windows
 * Buffer before return; writes perform no per-packet apartment initialization.
 * release drains callbacks immediately; native destruction may be deferred.
 * Lifecycle and writes are owner-serialized; receive callbacks must not reenter.
 * Callbacks run on native producers and only enqueue daemon messages or feed the passive adapter.
 */
typedef struct windows_transport windows_transport;

struct windows_transport {
    void *context;
    void (*release)(void *);
    bool (*subscribe)(void *, windows_receive, void *);
    bool (*resume)(void *);
    void (*stop)(void *);
    int32_t (*write)(void *, const uint8_t *, size_t, const windows_address *);
    bool (*local_address)(void *, windows_address *);
    bool unconnected;
};

typedef bool (*windows_configure)(void *, uintptr_t);

typedef struct {
    bool tcp;
    bool unconnected;
    bool dual_stack;
    int timeout_ms;
    windows_configure configure;
    void *context;
} windows_connect_options;

/* Creates, configures and opens a link in one operation. configure receives a
 * temporary native policy token; it must not retain or dereference that token.
 * Borrows the active runtime's loop; fails if no runtime is active. The owner
 * must outlive all transports and drain their queued destruction. */
windows_transport *windows_connect(const char *host, uint16_t port,
                                   const windows_connect_options *options);

/* Explicit owner API for standalone native consumers and tests. Only one loop
 * may be active. VpnChannelRuntime owns its loop directly in C++.
 * Before free: stop producers, drain preparation, release every transport and
 * drain teardown. Never free a borrowed handle or free on the worker itself. */
windows_loop windows_loop_create(void);
void windows_loop_free(windows_loop);
/* Borrowed lookup: the runtime owner must outlive every user of this handle. */
windows_loop windows_loop_current(void);
/* Accepted work executes once on the runtime worker. Drain is a barrier for
 * previously submitted commands; callers must first quiesce their producers. */
bool windows_loop_submit(windows_loop, void (*execute)(void *), void *context);
void windows_loop_drain(windows_loop);
#ifdef __cplusplus
}
#endif
