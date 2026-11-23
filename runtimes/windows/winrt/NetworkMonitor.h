// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "windows/export.h"

#include <winrt/Windows.Networking.Connectivity.h>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>

namespace Partout {
class NetworkMonitor {
public:
    // Adapter identity matters even when reachability remains true during a handoff.
    struct Path {
        winrt::guid adapter{};
        bool reachable = false;
        bool initialized = false;

        bool Update(winrt::guid id, bool available);
    };

    // A default route outranks a local-only path; lower combined metrics win.
    struct Preference {
        uint32_t connectivity = 0;
        std::optional<uint64_t> metric;

        bool IsBetterThan(const Preference &other) const;
    };

    // A missing preference excludes an unusable profile from selection.
    static std::optional<size_t> SelectPhysical(
        size_t count, const std::function<std::optional<Preference>(size_t)> &preference
    );
    static winrt::Windows::Networking::Connectivity::ConnectionProfile PhysicalProfile();

    PARTOUT_WINRT_API NetworkMonitor();
    PARTOUT_WINRT_API ~NetworkMonitor();

    // Callback arguments are (reachable, path_changed). The initial snapshot
    // reports path_changed=false; duplicate snapshots do not invoke the callback.
    PARTOUT_WINRT_API void Start(std::function<void(bool, bool)> notify);
    PARTOUT_WINRT_API void Stop();

private:
    struct State;
    std::shared_ptr<State> state_;
    winrt::Windows::Networking::Connectivity::NetworkInformation::NetworkStatusChanged_revoker
        registration_;
};
} // namespace Partout
