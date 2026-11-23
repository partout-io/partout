// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "WinRTTunnelStrategy.h"
#include "partout/tunnel/Tunnel.h"

using namespace Partout;

Tunnel::Tunnel(const std::string &serverUri) : Tunnel(std::make_unique<WinRTTunnelStrategy>(serverUri)) {}
