// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <chrono>
#include <partout/Export.h>
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
    // Maximum wait for a connect request, including credentials and engine startup.
    static constexpr auto ConnectRequestTimeout = std::chrono::seconds(120);
    // Default wait for native management operations, such as enumeration or disconnection.
    static constexpr auto ManagementOperationTimeout = std::chrono::seconds(60);
    // Delay between checks for asynchronous completion, cancellation, or timeout.
    static constexpr auto AsyncPollInterval = std::chrono::milliseconds(20);

    PARTOUT_API static std::optional<std::string> DecodeId(const winrt::hstring &xml);
    PARTOUT_API static bool NamesEqual(const winrt::hstring &left, const winrt::hstring &right);
    PARTOUT_API static std::optional<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus> ReadConnectionStatus(
        const std::function<winrt::Windows::Networking::Vpn::VpnManagementConnectionStatus()> &read,
        std::string &error
    );
    PARTOUT_API static std::optional<Models::TunnelSnapshotEnvironment> InterfaceEnvironment(const MIB_IF_ROW2 &row);

    PARTOUT_API explicit WinRTTunnelStrategy(const std::string &server_uri);

    PARTOUT_API ~WinRTTunnelStrategy() override;

    PARTOUT_API std::vector<Models::TunnelSnapshot> Fetch() override;
    PARTOUT_API std::map<std::string, std::string> ObservationErrors() const override;
    PARTOUT_API void Save(const Models::TaggedProfile &profile) override;
    PARTOUT_API void Connect(const std::string &id) override;
    PARTOUT_API void ConnectWithCredentials(const std::string &id, const TunnelCredentials &credentials) override;
    PARTOUT_API void Disconnect(const std::string &id) override;
    PARTOUT_API void Remove(const std::string &id) override;
    PARTOUT_API void Cancel() noexcept override;
private:
    std::string server_uri_;
    std::atomic_bool canceled_{false};
    std::map<std::string, std::string> observation_errors_;
};
}
