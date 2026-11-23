// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "Tunnel.h"

namespace {
class UnavailableTunnelStrategy final : public Partout::TunnelStrategy {
public:
    std::vector<Partout::Models::TunnelSnapshot> Fetch() override {
        throw std::runtime_error("VPN control is unavailable on this platform.");
    }

    void Save(const Partout::Models::TaggedProfile &) override {
        Fail();
    }

    void Connect(const std::string &) override {
        Fail();
    }

    void Disconnect(const std::string &) override {
        Fail();
    }

    void Remove(const std::string &) override {
        Fail();
    }

private:
    void Fail() {
        throw std::runtime_error("VPN control is unavailable on this platform.");
    }
};
}

std::unique_ptr<Partout::TunnelStrategy> Partout::TunnelStrategies::MakeNative(const std::string &) {
    return std::make_unique<UnavailableTunnelStrategy>();
}

Partout::Tunnel::Tunnel(const std::string &serverUri) : Tunnel(TunnelStrategies::MakeNative(serverUri)) {}
