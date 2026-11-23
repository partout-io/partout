// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <winsock2.h>
#include <ws2ipdef.h>
#include <netioapi.h>
#include <partout/tunnel/TunnelStrategy.h>
#include <atomic>
#include <functional>
#include <optional>
#include <string>
#include <winrt/Windows.Networking.Vpn.h>

namespace Partout {
class WinRTTunnelStrategy final : public TunnelStrategy {
public:
    static std::optional<std::string> DecodeId(const winrt::hstring &xml);
    static bool NamesEqual(const winrt::hstring &left, const winrt::hstring &right);
    static std::optional<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus> ReadConnectionStatus(
        const std::function<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus()> &read,
        std::string &error
    );
    static std::optional<Models::TunnelSnapshotEnvironment> InterfaceEnvironment(const MIB_IF_ROW2 &row);
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
