// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "windows/export.h"

#include <winrt/Windows.Networking.Connectivity.h>
#include <functional>
#include <memory>

namespace Partout {
winrt::Windows::Networking::Connectivity::ConnectionProfile PhysicalProfile();

class NetworkMonitor {
public:
    PARTOUT_WINDOWS_API NetworkMonitor();
    PARTOUT_WINDOWS_API ~NetworkMonitor();

    // Callback arguments are (reachable, path_changed). The initial snapshot
    // reports path_changed=false; duplicate snapshots do not invoke the callback.
    PARTOUT_WINDOWS_API void Start(std::function<void(bool, bool)> notify);
    PARTOUT_WINDOWS_API void Stop();

private:
    struct State;
    std::shared_ptr<State> state_;
    winrt::Windows::Networking::Connectivity::NetworkInformation::NetworkStatusChanged_revoker
        registration_;
};
} // namespace Partout
