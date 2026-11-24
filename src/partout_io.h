/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */
#pragma once
#include "partout.h"

/* Numeric packet endpoint: family 4 or 6, host-endian port and scope_id. */
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} partout_socket_address;

/* A receive callback reports zero for data, this marker for EOF, or an error. */
enum { PartoutTransportEOF = 1 };

typedef bool (*partout_transport_receive)(void *, const uint8_t *, size_t, const partout_socket_address *, int32_t);

/* Owned transport capability, shared by daemon and passive consumers.
 * subscribe(NULL) drains borrowed callback contexts. Writes must copy borrowed packet data before returning.
 * release drains callbacks immediately; native destruction may be deferred.
 * Lifecycle and writes are owner-serialized; receive callbacks must not reenter.
 * Callbacks run on native producers and must not reenter the daemon.
 */
typedef struct partout_transport partout_transport;

struct partout_transport {
    void *context;
    void (*release)(void *);
    bool (*subscribe)(void *, partout_transport_receive, void *);
    bool (*resume)(void *);
    void (*stop)(void *);
    int32_t (*write)(void *, const uint8_t *, size_t, const partout_socket_address *);
    bool (*local_address)(void *, partout_socket_address *);
    bool unconnected;
};

/* Shared socket creation contract for readiness and callback-based backends. */
typedef enum {
    PartoutSocketProtoTCP,
    PartoutSocketProtoUDP
} partout_socket_proto;

typedef bool (*partout_socket_configure)(void *, partout_socket_descriptor, const partout_reachability *);

typedef struct {
    bool unconnected;
    bool dual_stack;
    int timeout_ms;
    const partout_reachability *reachability;
    partout_socket_configure configure;
    void *configure_ctx;
} partout_socket_open_options;

/* The core copies this table. context and all referenced resources must remain
 * valid until daemon bindings release. submit executes accepted work once;
 * drain waits for accepted work. Callbacks must not throw across the C ABI. */
struct partout_winrt_callbacks {
    void *context;
    partout_transport *(*connect)(void *, const char *, partout_socket_proto, uint16_t, const partout_socket_open_options *);
    bool (*submit)(void *, void (*execute)(void *), void *);
    void (*drain)(void *);
};
