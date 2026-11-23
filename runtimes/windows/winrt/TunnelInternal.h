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
namespace WinRT::Profiles {
bool NamesEqual(const winrt::hstring &left, const winrt::hstring &right);
}

namespace WinRT::Tunnels {
std::optional<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus> ReadConnectionStatus(
    const std::function<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus()> &read,
    std::string &error
);
std::optional<Models::TunnelSnapshotEnvironment> InterfaceEnvironment(const MIB_IF_ROW2 &row);
}
}
