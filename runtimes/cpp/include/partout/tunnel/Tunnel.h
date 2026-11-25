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
class PARTOUT_API Tunnel {
public:
    // Default wait for each observed disconnect/connect phase when switching tunnels.
    static constexpr auto HandoverTimeout = std::chrono::seconds(60);

    // Call from a serialized background executor. Cancel may run concurrently.
    explicit Tunnel(
        std::unique_ptr<TunnelStrategy> strategy,
        std::chrono::milliseconds handover_timeout = HandoverTimeout
    );

    std::vector<Models::TunnelSnapshot> Fetch();
    std::map<std::string, std::string> ObservationErrors() const;

    void Save(const Models::TaggedProfile &profile);
    void Connect(const Models::TaggedProfile &profile, std::optional<TunnelCredentials> credentials = {});
    void Disconnect(const std::string &id);
    void Remove(const std::string &id);

    void Advance();
    void Cancel() noexcept;

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
