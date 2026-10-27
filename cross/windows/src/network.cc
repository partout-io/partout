// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "network.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <mutex>
#include <utility>

namespace Partout {
namespace {
constexpr uint32_t kEthernetInterfaceType = 6; // IANA ethernetCsmacd.
}

bool NetworkPath::Update(winrt::guid id, bool available) {
    if (initialized && available == reachable && id == adapter) return false;
    initialized = true;
    reachable = available;
    adapter = id;
    return true;
}

// Exclude the VPN interface itself when Windows reports it as the preferred path.
winrt::Windows::Networking::Connectivity::ConnectionProfile PhysicalProfile() {
    using namespace winrt::Windows::Networking::Connectivity;
    const auto usable = [](ConnectionProfile const &profile) {
        if (!profile || !profile.NetworkAdapter()) return false;
        const auto type = profile.NetworkAdapter().IanaInterfaceType();
        // WLAN and WWAN have dedicated profile flags; accept these three
        // physical network kinds.
        // Local access is sufficient: the remote endpoint may be on the LAN.
        return (type == kEthernetInterfaceType || profile.IsWlanConnectionProfile() || profile.IsWwanConnectionProfile()) &&
            profile.GetNetworkConnectivityLevel() != NetworkConnectivityLevel::None;
    };
    auto selected = NetworkInformation::GetInternetConnectionProfile();
    if (usable(selected)) return selected;
    // The preferred profile may belong to the VPN. Fall back to a connected
    // physical profile, favoring the highest reported connectivity level.
    selected = nullptr;
    for (auto const &profile : NetworkInformation::GetConnectionProfiles()) {
        if (!usable(profile)) continue;
        if (!selected || profile.GetNetworkConnectivityLevel() > selected.GetNetworkConnectivityLevel()) {
            selected = profile;
        }
    }
    return selected;
}

struct NetworkMonitor::State {
    std::mutex mutex;
    std::function<void(bool, bool)> notify;
    NetworkPath path;

    void Refresh() noexcept {
        try {
            std::lock_guard lock(mutex);
            if (!notify) return;
            const auto profile = PhysicalProfile();
            const bool available = bool(profile);
            // Use an empty adapter ID for the offline state so repeated offline
            // notifications compare equal, just like repeated adapter notifications.
            const auto id = available ? profile.NetworkAdapter().NetworkAdapterId() : winrt::guid{};
            // The first snapshot establishes reachability without requesting a
            // path refresh. Later distinct snapshots describe actual transitions.
            const bool changed = path.initialized;
            if (!path.Update(id, available)) return;
            // Delegate removal takes this same lock, draining borrowed contexts.
            notify(available, changed);
        } catch (...) {
            // Transient profile-query failures must not escape a system callback.
        }
    }
};

NetworkMonitor::NetworkMonitor() : state_(std::make_shared<State>()) {}

NetworkMonitor::~NetworkMonitor() {
    Stop();
}

void NetworkMonitor::Start(std::function<void(bool, bool)> notify) {
    Stop();
    {
        std::lock_guard lock(state_->mutex);
        state_->notify = std::move(notify);
    }
    // A queued system event may outlive the subscription. Locking a weak state
    // reference avoids retaining or dereferencing the destroyed monitor.
    const std::weak_ptr<State> weak = state_;
    registration_ = winrt::Windows::Networking::Connectivity::NetworkInformation::NetworkStatusChanged(
        winrt::auto_revoke, [weak](auto const &) {
            if (auto state = weak.lock()) state->Refresh();
        });
    // Subscribe before querying so a transition during startup is not missed.
    state_->Refresh();
}

void NetworkMonitor::Stop() {
    {
        // Wait for any active notification and disable delivery before revoking;
        // an already queued event then sees an empty callback and does nothing.
        std::lock_guard lock(state_->mutex);
        state_->notify = nullptr;
        state_->path = {};
    }
    registration_.revoke();
}
} // namespace Partout
