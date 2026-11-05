// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <winsock2.h>
#include <ws2ipdef.h>
#include <netioapi.h>
#include <winrt/base.h>
#include "partout/models/TunnelSnapshotEnvironment.h"
#include <optional>
#include <string>
#include <functional>
#include <winrt/Windows.Networking.Vpn.h>

namespace Partout {
std::optional<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus> ReadTunnelConnectionStatus(
    const std::function<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus()> &read,
    std::string &error);
std::optional<Models::TunnelSnapshotEnvironment> TunnelInterfaceEnvironment(const MIB_IF_ROW2 &row);
}
