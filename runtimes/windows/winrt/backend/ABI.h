// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <partout_io.h>
#include <memory>

namespace Partout {
class RuntimeLoop;
class Tun;
class TunnelController;

// Native integration helpers; the capability's owner stays private to abi.cc.
namespace ABI {
partout_transport *WrapTun(RuntimeLoop &, std::unique_ptr<Tun>);
bool ConfigureSocket(TunnelController *, uintptr_t token);

/* Creates, configures and opens a link in one operation. configure receives a
 * temporary native policy token; it must not retain or dereference that token.
 * Borrows the supplied loop; its owner must outlive all transports and drain
 * their queued destruction. */
partout_transport *ConnectOnLoop(
    RuntimeLoop *, const char *, partout_socket_proto, uint16_t,
    const partout_socket_open_options *
);

/* Explicit owner API for standalone native consumers and tests. Only one loop
 * may be active. VpnChannelRuntime owns its loop directly in C++.
 * Before free: stop producers, drain preparation, release every transport and
 * drain teardown. Never free a borrowed handle or free on the worker itself. */
RuntimeLoop *CreateLoop();
void FreeLoop(RuntimeLoop *);
/* Borrowed lookup: the runtime owner must outlive every user of this handle. */
RuntimeLoop *CurrentLoop();
/* Accepted work executes once on the runtime worker. Drain is a barrier for
 * previously submitted commands; callers must first quiesce their producers. */
bool SubmitLoop(RuntimeLoop *, void (*execute)(void *), void *context);
void DrainLoop(RuntimeLoop *);
} // namespace ABI
} // namespace Partout
