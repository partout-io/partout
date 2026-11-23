// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "TunnelStrategy.h"
#include <atomic>
#include <chrono>
#include <optional>

namespace Partout {
// Owns registration, connection handover, and pending activation. Snapshots use
// the same runtime models as the Apple and Android tunnel facades.
class Tunnel {
public:
    // Default wait for each observed disconnect/connect phase when switching tunnels.
    static constexpr auto HandoverTimeout = std::chrono::seconds(60);

    // Call from a serialized background executor. Cancel may run concurrently.
    explicit Tunnel(std::unique_ptr<TunnelStrategy> strategy,
                    std::chrono::milliseconds handover_timeout = HandoverTimeout
    );
    // Advance pending activation when polling on the owning executor.
    void Advance();
    void CancelPending(const std::string &id);
    std::optional<std::string> PendingProfile() const;
    // Fetch is read-only; unavailable registrations appear in ObservationErrors.
    std::vector<Models::TunnelSnapshot> Fetch();
    std::map<std::string, std::string> ObservationErrors() const;
    void Save(const Models::TaggedProfile &profile);
    void Register(const Models::TaggedProfile &profile);
    void ValidateNew(const Models::TaggedProfile &profile);
    void ValidateUpdate(const Models::TaggedProfile &profile);
    // Removes only an inactive registration; never disconnects during rollback.
    void RollbackRegistration(const std::string &id);
    void Connect(const Models::TaggedProfile &profile, std::optional<TunnelCredentials> credentials = {});
    void Disconnect(const std::string &id);
    void Remove(const std::string &id);
    // Permanently cancels management, without disconnecting the active VPN.
    void Cancel() noexcept;
private:
    void RequireActive() const;
    std::atomic_bool canceled_{false};
    std::unique_ptr<TunnelStrategy> strategy_;
    std::optional<Models::TaggedProfile> pending_;
    std::optional<TunnelCredentials> pending_credentials_;
    bool connection_requested_ = false;
    bool saw_connecting_ = false;
    std::chrono::steady_clock::time_point handover_started_;
    std::chrono::milliseconds handover_timeout_;
};
}
