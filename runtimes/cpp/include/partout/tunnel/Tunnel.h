// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "TunnelStrategy.h"
#include <partout/Export.h>
#include <atomic>
#include <chrono>
#include <optional>

namespace Partout {
// Owns registration, connection handover, and pending activation. Snapshots use
// the same runtime models as the Apple and Android tunnel facades.
class Tunnel final {
public:
    // Default wait for each observed disconnect/connect phase when switching tunnels.
    static constexpr auto HandoverTimeout = std::chrono::seconds(60);

    // Call from a serialized background executor. Cancel may run concurrently.
    PARTOUT_API explicit Tunnel(
        std::unique_ptr<TunnelStrategy> strategy,
        std::chrono::milliseconds handover_timeout = HandoverTimeout
    );

    PARTOUT_API ~Tunnel();

    PARTOUT_API std::vector<Models::TunnelSnapshot> Fetch();
    PARTOUT_API std::map<std::string, std::string> ObservationErrors() const;

    PARTOUT_API void Save(const Models::TaggedProfile &profile);
    PARTOUT_API void Connect(const Models::TaggedProfile &profile, std::optional<TunnelCredentials> credentials = {});
    PARTOUT_API void Disconnect(const std::string &id);
    PARTOUT_API void Remove(const std::string &id);

    PARTOUT_API void Advance();
    PARTOUT_API void Cancel() noexcept;

private:
    void RequireActive() const;
    std::atomic_bool canceled_{false};
    std::unique_ptr<TunnelStrategy> strategy_;
    std::optional<Models::TaggedProfile> pending_profile_;
    std::optional<TunnelCredentials> pending_credentials_;
    bool connection_requested_ = false;
    bool saw_connecting_ = false;
    std::chrono::steady_clock::time_point handover_started_;
    std::chrono::milliseconds handover_timeout_;
};
}
