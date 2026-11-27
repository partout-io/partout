// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "TunnelStrategy.h"
#include <partout/Export.h>
#include <atomic>
#include <chrono>
#include <optional>
#include <set>

namespace Partout {
// Owns registration, connection handover, and pending activation. Snapshots use
// the same runtime models as the Apple and Android tunnel facades.
class Tunnel final {
public:
    // Default wait for each observed disconnect/connect phase when switching tunnels.
    static constexpr auto HandoverTimeout = std::chrono::seconds(60);

    // Call from a serialized background executor. Cancel may run concurrently.
    PARTOUT_RUNTIME_API explicit Tunnel(
        std::unique_ptr<TunnelStrategy> strategy,
        std::chrono::milliseconds handover_timeout = HandoverTimeout
    );

    PARTOUT_RUNTIME_API ~Tunnel();

    PARTOUT_RUNTIME_API std::vector<Models::TunnelSnapshot> Fetch();
    PARTOUT_RUNTIME_API std::map<std::string, std::string> ObservationErrors() const;

    PARTOUT_RUNTIME_API void Save(const Models::TaggedProfile &profile);
    // Installs the supplied profile after any active connection has stopped.
    PARTOUT_RUNTIME_API void Connect(const Models::TaggedProfile &profile, std::optional<TunnelCredentials> credentials = {});
    PARTOUT_RUNTIME_API void Disconnect(const std::string &id);
    // Disconnects first when needed; Advance completes deferred removal.
    PARTOUT_RUNTIME_API void Remove(const std::string &id);

    PARTOUT_RUNTIME_API std::optional<std::string> PendingProfile() const;
    // Poll to advance pending connection and removal operations.
    PARTOUT_RUNTIME_API void Advance();
    PARTOUT_RUNTIME_API void Cancel() noexcept;

private:
    void RequireActive() const;
    std::atomic_bool canceled_{false};
    std::unique_ptr<TunnelStrategy> strategy_;
    std::optional<Models::TaggedProfile> pending_profile_;
    std::optional<TunnelCredentials> pending_credentials_;
    std::set<std::string> pending_removals_;
    bool connection_requested_ = false;
    bool saw_connecting_ = false;
    std::chrono::steady_clock::time_point handover_started_;
    std::chrono::milliseconds handover_timeout_;
};
}
