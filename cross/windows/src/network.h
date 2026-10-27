// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

#include <winrt/Windows.Networking.Connectivity.h>
#include <functional>
#include <memory>
#include <optional>

namespace Partout {
// Adapter identity matters even when reachability remains true during a handoff.
struct NetworkPath {
    winrt::guid adapter{};
    bool reachable = false;
    bool initialized = false;

    bool Update(winrt::guid id, bool available);
};

winrt::Windows::Networking::Connectivity::ConnectionProfile PhysicalProfile();

// A default route outranks a local-only path; lower combined metrics win.
struct NetworkPreference {
    uint32_t connectivity = 0;
    std::optional<uint64_t> metric;

    bool IsBetterThan(const NetworkPreference &other) const;
};

class NetworkMonitor {
public:
    NetworkMonitor();
    ~NetworkMonitor();

    // Callback arguments are (reachable, path_changed). The initial snapshot
    // reports path_changed=false; duplicate snapshots do not invoke the callback.
    void Start(std::function<void(bool, bool)> notify);
    void Stop();

private:
    struct State;
    std::shared_ptr<State> state_;
    winrt::Windows::Networking::Connectivity::NetworkInformation::NetworkStatusChanged_revoker registration_;
};
} // namespace Partout
