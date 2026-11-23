// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <partout/tunnel/TunnelStrategy.h>
#include <atomic>
#include <optional>
#include <string>
#include <winrt/base.h>

namespace Partout {
class WinRTTunnelStrategy final : public TunnelStrategy {
public:
    explicit WinRTTunnelStrategy(const std::string &serverUri);
    std::vector<Models::TunnelSnapshot> Fetch() override;
    std::map<std::string, std::string> ObservationErrors() const override;
    void Save(const Models::TaggedProfile &profile) override;
    void Connect(const std::string &id) override;
    void ConnectWithCredentials(const std::string &id, const TunnelCredentials &credentials) override;
    void Disconnect(const std::string &id) override;
    void Remove(const std::string &id) override;
    void Cancel() noexcept override;
private:
    std::string serverUri_;
    std::atomic_bool canceled_{false};
    std::map<std::string, std::string> observationErrors_;
};
}

namespace Partout::WinRT::Profiles {
std::optional<std::string> DecodeId(const winrt::hstring &xml);
}
