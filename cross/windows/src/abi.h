// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "winrt/abi.h"
#include <memory>

namespace Partout {
class Tun;
class TunnelController;

// Native integration helpers; the capability's owner stays private to abi.cc.
namespace ABI {
winrt_transport *WrapTun(RuntimeLoop &, std::unique_ptr<Tun>);
bool ConfigureSocket(TunnelController *, uintptr_t token);
} // namespace ABI
} // namespace Partout
