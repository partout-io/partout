// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <partout/tunnel/Tunnel.h>
#include <algorithm>
#include <stdexcept>

namespace Partout {
void Tunnel::Cancel() noexcept {
    canceled_.store(true);
    strategy_->Cancel();
}

Tunnel::Tunnel(std::unique_ptr<TunnelStrategy> strategy,
               std::chrono::milliseconds handoverTimeout
)
    : strategy_(std::move(strategy)), handoverTimeout_(handoverTimeout) {
    if (!strategy_) throw std::invalid_argument("A tunnel strategy is required.");
}

void Tunnel::RequireActive() const {
    if (canceled_.load()) throw std::runtime_error("Tunnel management was canceled.");
}

std::vector<Models::TunnelSnapshot> Tunnel::Fetch() {
    RequireActive();
    return strategy_->Fetch();
}

std::map<std::string, std::string> Tunnel::ObservationErrors() const {
    return strategy_->ObservationErrors();
}

void Tunnel::Save(const Models::TaggedProfile &profile) {
    RequireActive();
    strategy_->Save(profile);
}

void Tunnel::Register(const Models::TaggedProfile &profile) {
    ValidateNew(profile);
    Save(profile);
}

void Tunnel::ValidateNew(const Models::TaggedProfile &profile) {
    const auto existing = Fetch();
    if (ObservationErrors().count(profile.id) || std::any_of(existing.begin(), existing.end(), [&](const auto &info) {
        return info.id == profile.id;
    })) throw std::runtime_error("The VPN profile is already registered.");
}

void Tunnel::ValidateUpdate(const Models::TaggedProfile &profile) {
    if (pending_) throw std::runtime_error("Wait for the pending VPN action before saving.");
    const auto tunnels = Fetch();
    if (ObservationErrors().count(profile.id))
        throw std::runtime_error("Unable to observe the VPN profile before updating.");
    for (const auto &tunnel : tunnels) {
        if (tunnel.id == profile.id && (tunnel.isEnabled || tunnel.status.value != Models::TunnelStatus::inactive))
            throw std::runtime_error("Disconnect the VPN before saving this profile.");
    }
}

void Tunnel::RollbackRegistration(const std::string &id) {
    RequireActive();
    // Never disconnect a connection as a side effect of import rollback.
    strategy_->Remove(id);
}

void Tunnel::Connect(const Models::TaggedProfile &profile, std::optional<TunnelCredentials> credentials) {
    pending_.reset();
    pendingCredentials_.reset();
    connectionRequested_ = false;
    sawConnecting_ = false;
    const auto tunnels = Fetch();
    const auto errors = ObservationErrors();
    if (const auto failure = errors.find(profile.id); failure != errors.end())
        throw std::runtime_error(failure->second);
    if (std::none_of(tunnels.begin(), tunnels.end(), [&](const auto &tunnel) { return tunnel.id == profile.id; }))
        throw std::runtime_error("The VPN profile is not installed.");
    for (const auto &tunnel : tunnels) {
        if (tunnel.id == profile.id && tunnel.status.value == Models::TunnelStatus::active) return;
    }
    for (const auto &tunnel : tunnels) {
        if (tunnel.status.value == Models::TunnelStatus::inactive || tunnel.status.value == Models::TunnelStatus::deactivating) continue;
        strategy_->Disconnect(tunnel.id);
    }
    pending_ = profile;
    pendingCredentials_ = std::move(credentials);
    handoverStarted_ = std::chrono::steady_clock::now();
    Advance();
}

void Tunnel::Advance() {
    if (!pending_) return;
    try {
        const auto tunnels = Fetch();
        const auto errors = ObservationErrors();
        if (const auto failure = errors.find(pending_->id); failure != errors.end())
            throw std::runtime_error(failure->second);
        if (connectionRequested_) {
            const auto target = std::find_if(tunnels.begin(), tunnels.end(), [&](const auto &tunnel) {
                return tunnel.id == pending_->id;
            });
            if (target != tunnels.end() && target->status.value == Models::TunnelStatus::active) {
                pending_.reset();
                pendingCredentials_.reset();
                return;
            }
            if (target != tunnels.end() && target->status.value == Models::TunnelStatus::activating) sawConnecting_ = true;
            if (sawConnecting_ && (target == tunnels.end() || target->status.value == Models::TunnelStatus::inactive))
                throw std::runtime_error("The VPN disconnected before activation completed.");
            if (std::chrono::steady_clock::now() - handoverStarted_ >= handoverTimeout_)
                throw std::runtime_error("Timed out waiting for the requested VPN to connect.");
            return;
        }
        const bool active = std::any_of(tunnels.begin(), tunnels.end(), [](const auto &tunnel) {
            return tunnel.status.value != Models::TunnelStatus::inactive;
        });
        if (active) {
            if (std::chrono::steady_clock::now() - handoverStarted_ >= handoverTimeout_)
                throw std::runtime_error("Timed out waiting for the active VPN to disconnect.");
            return;
        }
        // Wait for observed connections; unavailable registrations are neither
        // treated as disconnected nor selected for automatic disconnection.
        if (pendingCredentials_) strategy_->ConnectWithCredentials(pending_->id, *pendingCredentials_);
        else strategy_->Connect(pending_->id);
        pendingCredentials_.reset();
        connectionRequested_ = true;
        handoverStarted_ = std::chrono::steady_clock::now();
        Advance();
    } catch (...) {
        pending_.reset();
        pendingCredentials_.reset();
        throw;
    }
}

std::optional<std::string> Tunnel::PendingProfile() const {
    if (canceled_.load() || !pending_) return std::nullopt;
    return pending_->id;
}

void Tunnel::CancelPending(const std::string &id) {
    if (pending_ && pending_->id == id) {
        pending_.reset();
        pendingCredentials_.reset();
    }
}

void Tunnel::Disconnect(const std::string &id) {
    pending_.reset();
    pendingCredentials_.reset();
    RequireActive();
    strategy_->Disconnect(id);
}

void Tunnel::Remove(const std::string &id) {
    if (pending_ && pending_->id == id) {
        pending_.reset();
        pendingCredentials_.reset();
    }
    const auto tunnels = Fetch();
    if (ObservationErrors().count(id))
        throw std::runtime_error("Unable to observe the VPN profile before removal.");
    for (const auto &tunnel : tunnels) {
        if (tunnel.id != id || tunnel.status.value == Models::TunnelStatus::inactive) continue;
        strategy_->Disconnect(id);
        // An accepted disconnect is not necessarily a completed disconnect.
        const auto currentTunnels = Fetch();
        if (ObservationErrors().count(id))
            throw std::runtime_error("Unable to observe the VPN profile after disconnection.");
        for (const auto &current : currentTunnels) {
            if (current.id == id && current.status.value != Models::TunnelStatus::inactive)
                throw std::runtime_error("The VPN is still disconnecting. Retry removal when disconnected.");
        }
    }
    strategy_->Remove(id);
}
}
