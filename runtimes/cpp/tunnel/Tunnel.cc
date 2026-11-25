// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <partout/tunnel/Tunnel.h>
#include <algorithm>
#include <stdexcept>

namespace Partout {
Tunnel::Tunnel(
    std::unique_ptr<TunnelStrategy> strategy,
    std::chrono::milliseconds handover_timeout
) : strategy_(std::move(strategy)), handover_timeout_(handover_timeout) {
    if (!strategy_) throw std::invalid_argument("A tunnel strategy is required.");
}

Tunnel::~Tunnel() = default;

std::vector<Models::TunnelSnapshot> Tunnel::Fetch() {
    RequireActive();
    return strategy_->Fetch();
}

std::map<std::string, std::string> Tunnel::ObservationErrors() const {
    return strategy_->ObservationErrors();
}

void Tunnel::Save(const Models::TaggedProfile &profile) {
    RequireActive();
    if (pending_profile_) throw std::runtime_error("Wait for the pending VPN action before saving.");
    const auto tunnels = Fetch();
    if (ObservationErrors().count(profile.id))
        throw std::runtime_error("Unable to observe the VPN profile before updating.");
    for (const auto &tunnel : tunnels) {
        if (tunnel.id == profile.id && (tunnel.isEnabled || tunnel.status.value != Models::TunnelStatus::inactive))
            throw std::runtime_error("Disconnect the VPN before saving this profile.");
    }
    strategy_->Save(profile);
}

void Tunnel::Connect(const Models::TaggedProfile &profile, std::optional<TunnelCredentials> credentials) {
    pending_profile_.reset();
    pending_credentials_.reset();
    connection_requested_ = false;
    saw_connecting_ = false;
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
    pending_profile_ = profile;
    pending_credentials_ = std::move(credentials);
    handover_started_ = std::chrono::steady_clock::now();
    Advance();
}

void Tunnel::Disconnect(const std::string &id) {
    pending_profile_.reset();
    pending_credentials_.reset();
    RequireActive();
    strategy_->Disconnect(id);
}

void Tunnel::Remove(const std::string &id) {
    if (pending_profile_ && pending_profile_->id == id) {
        pending_profile_.reset();
        pending_credentials_.reset();
    }
    const auto tunnels = Fetch();
    if (ObservationErrors().count(id))
        throw std::runtime_error("Unable to observe the VPN profile before removal.");
    for (const auto &tunnel : tunnels) {
        if (tunnel.id != id || tunnel.status.value == Models::TunnelStatus::inactive) continue;
        strategy_->Disconnect(id);
        // An accepted disconnect is not necessarily a completed disconnect.
        const auto current_tunnels = Fetch();
        if (ObservationErrors().count(id))
            throw std::runtime_error("Unable to observe the VPN profile after disconnection.");
        for (const auto &current : current_tunnels) {
            if (current.id == id && current.status.value != Models::TunnelStatus::inactive)
                throw std::runtime_error("The VPN is still disconnecting. Retry removal when disconnected.");
        }
    }
    strategy_->Remove(id);
}

void Tunnel::Advance() {
    if (!pending_profile_) return;
    try {
        const auto tunnels = Fetch();
        const auto errors = ObservationErrors();
        if (const auto failure = errors.find(pending_profile_->id); failure != errors.end())
            throw std::runtime_error(failure->second);
        if (connection_requested_) {
            const auto target = std::find_if(tunnels.begin(), tunnels.end(), [&](const auto &tunnel) {
                return tunnel.id == pending_profile_->id;
            });
            if (target != tunnels.end() && target->status.value == Models::TunnelStatus::active) {
                pending_profile_.reset();
                pending_credentials_.reset();
                return;
            }
            if (target != tunnels.end() && target->status.value == Models::TunnelStatus::activating) saw_connecting_ = true;
            if (saw_connecting_ && (target == tunnels.end() || target->status.value == Models::TunnelStatus::inactive))
                throw std::runtime_error("The VPN disconnected before activation completed.");
            if (std::chrono::steady_clock::now() - handover_started_ >= handover_timeout_)
                throw std::runtime_error("Timed out waiting for the requested VPN to connect.");
            return;
        }
        const bool active = std::any_of(tunnels.begin(), tunnels.end(), [](const auto &tunnel) {
            return tunnel.status.value != Models::TunnelStatus::inactive;
        });
        if (active) {
            if (std::chrono::steady_clock::now() - handover_started_ >= handover_timeout_)
                throw std::runtime_error("Timed out waiting for the active VPN to disconnect.");
            return;
        }
        // Wait for observed connections; unavailable registrations are neither
        // treated as disconnected nor selected for automatic disconnection.
        if (pending_credentials_) strategy_->ConnectWithCredentials(pending_profile_->id, *pending_credentials_);
        else strategy_->Connect(pending_profile_->id);
        pending_credentials_.reset();
        connection_requested_ = true;
        handover_started_ = std::chrono::steady_clock::now();
        Advance();
    } catch (...) {
        pending_profile_.reset();
        pending_credentials_.reset();
        throw;
    }
}

void Tunnel::Cancel() noexcept {
    canceled_.store(true);
    strategy_->Cancel();
}

void Tunnel::RequireActive() const {
    if (canceled_.load()) throw std::runtime_error("Tunnel management was canceled.");
}
}
