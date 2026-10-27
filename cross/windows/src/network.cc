// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include <ws2ipdef.h>
#include "network.h"
#include <windows.h>
#include <ipifcons.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <mutex>
#include <utility>

namespace Partout {
bool NetworkPreference::IsBetterThan(const NetworkPreference &other) const {
    if (metric == other.metric) return connectivity > other.connectivity;
    return metric && (!other.metric || *metric < *other.metric);
}

std::optional<size_t> SelectPhysicalNetwork(size_t count,
    const std::function<std::optional<NetworkPreference>(size_t)> &preference) {
    std::optional<size_t> selected;
    NetworkPreference best{};
    for (size_t i = 0; i < count; ++i) {
        const auto candidate = preference(i);
        if (!candidate) continue;
        if (!selected || candidate->IsBetterThan(best)) {
            selected = i;
            best = *candidate;
        }
    }
    return selected;
}

namespace {
std::optional<uint64_t> DefaultRouteMetric(winrt::guid adapter, const MIB_IPFORWARD_TABLE2 *routes) {
    if (!routes) return std::nullopt;
    std::optional<uint64_t> best;
    for (ULONG i = 0; i < routes->NumEntries; ++i) {
        const auto &route = routes->Table[i];
        // Ignore more-specific routes, including the VPN's split default /1s.
        if (route.DestinationPrefix.PrefixLength != 0 || route.ValidLifetime == 0) continue;
        GUID id{};
        if (ConvertInterfaceLuidToGuid(&route.InterfaceLuid, &id) != NO_ERROR || winrt::guid{id} != adapter) continue;
        MIB_IPINTERFACE_ROW ip_interface{};
        InitializeIpInterfaceEntry(&ip_interface);
        ip_interface.Family = route.DestinationPrefix.Prefix.si_family;
        ip_interface.InterfaceLuid = route.InterfaceLuid;
        if (GetIpInterfaceEntry(&ip_interface) != NO_ERROR || !ip_interface.Connected) continue;
        const uint64_t metric = uint64_t{route.Metric} + ip_interface.Metric;
        if (!best || metric < *best) best = metric;
    }
    return best;
}
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
        return (type == IF_TYPE_ETHERNET_CSMACD || profile.IsWlanConnectionProfile() || profile.IsWwanConnectionProfile()) &&
            profile.GetNetworkConnectivityLevel() != NetworkConnectivityLevel::None;
    };
    const auto preferred = NetworkInformation::GetInternetConnectionProfile();
    if (usable(preferred)) return preferred;
    // The VPN may mask the preferred physical profile. Compare physical default
    // route costs rather than enumeration order when several remain connected.
    MIB_IPFORWARD_TABLE2 *raw_routes = nullptr;
    const auto result = GetIpForwardTable2(AF_UNSPEC, &raw_routes);
    const std::unique_ptr<MIB_IPFORWARD_TABLE2, decltype(&FreeMibTable)> routes(raw_routes, FreeMibTable);
    if (result != NO_ERROR) throw winrt::hresult_error(HRESULT_FROM_WIN32(result));
    const auto profiles = NetworkInformation::GetConnectionProfiles();
    const auto selected = SelectPhysicalNetwork(profiles.Size(), [&](size_t i) -> std::optional<NetworkPreference> {
        const auto profile = profiles.GetAt(static_cast<uint32_t>(i));
        if (!usable(profile)) return std::nullopt;
        return NetworkPreference{
            static_cast<uint32_t>(profile.GetNetworkConnectivityLevel()),
            DefaultRouteMetric(profile.NetworkAdapter().NetworkAdapterId(), routes.get())};
    });
    return selected ? profiles.GetAt(static_cast<uint32_t>(*selected)) : ConnectionProfile{nullptr};
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
