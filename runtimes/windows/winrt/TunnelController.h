// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <chrono>
#include "Tun.h"
#include "NetworkMonitor.h"
#include <partout/models/TunnelControllerOptions.h>
#include <memory>

namespace Partout {
class RuntimeLoop;

// Association, Open and Close run on the same native worker. Destruction follows
// daemon shutdown. Native receives share Tun's gate.
class TunnelController {
public:
    // Maximum wait to establish the transport required before tunnel startup.
    static constexpr auto TransportSetupTimeout = std::chrono::seconds(5);

    PARTOUT_WINRT_API TunnelController(
        RuntimeLoop &, winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        Models::TunnelControllerOptions controllerOptions = {}
    );
    PARTOUT_WINRT_API ~TunnelController();
    TunnelController(const TunnelController &) = delete;
    TunnelController &operator=(const TunnelController &) = delete;

    bool Associate(Socket &socket) noexcept;

    RuntimeLoop &Loop() const {
        return loop_;
    }

    NetworkMonitor &Monitor() {
        return monitor_;
    }

    PARTOUT_WINRT_API std::unique_ptr<Tun> Open(const char *info_json);
    PARTOUT_WINRT_API void Close() noexcept;
    PARTOUT_WINRT_API void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    PARTOUT_WINRT_API void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

private:
    void AssociateUnconnected(Socket &socket);
    RuntimeLoop &loop_; // Runtime closes and destroys the controller before the loop.
    Models::TunnelControllerOptions controllerOptions_;
    NetworkMonitor monitor_;

    // Handles and socket writers are drained before controller destruction.
    std::unique_ptr<Tun::State> state_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket idle_transport_{nullptr};
    winrt::Windows::Networking::Connectivity::NetworkAdapter udp_adapter_{nullptr};
    bool started_ = false;
    Socket *socket_ = nullptr; // Borrowed until Open takes over; the link owns it.
};

} // namespace Partout
