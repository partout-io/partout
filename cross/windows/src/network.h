// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

#include <winrt/Windows.Networking.Connectivity.h>
#include <functional>
#include <memory>

namespace Partout {
// Adapter identity matters even when reachability remains true during a handoff.
struct NetworkPath {
    winrt::guid adapter{};
    bool reachable = false;
    bool initialized = false;

    bool Update(winrt::guid id, bool available);
};

winrt::Windows::Networking::Connectivity::ConnectionProfile PhysicalProfile();

class NetworkMonitor {
public:
    NetworkMonitor();
    ~NetworkMonitor();

    void Start(std::function<void(bool, bool)> notify);
    void Stop();

private:
    struct State;
    std::shared_ptr<State> state_;
    winrt::Windows::Networking::Connectivity::NetworkInformation::NetworkStatusChanged_revoker registration_;
};
} // namespace Partout
