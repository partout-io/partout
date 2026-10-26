// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include "winrt/tun.h"
#include "socket.h"
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.Vpn.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <memory>
#include <mutex>

struct WinrtTun;
struct WinrtPacketCounters;

namespace Partout {

// Internal platform ref. Daemon bindings retain the channel until callbacks drain.
class TunnelController {
public:
    explicit TunnelController(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    ~TunnelController();
    TunnelController(const TunnelController &) = delete;
    TunnelController &operator=(const TunnelController &) = delete;

    bool Associate(Socket *socket) noexcept;
    bool Start(const char *info_json) noexcept;
    void Stop() noexcept;
    winrt_tun Open(const char *info_json);
    void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

private:
    winrt::Windows::Networking::Vpn::VpnChannel channel_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket idle_transport_{nullptr};
    winrt::Windows::Networking::Connectivity::NetworkAdapter udp_adapter_{nullptr};
    bool started_ = false;
    Socket *socket_ = nullptr; // Borrowed until Start; the link owns it.
    std::shared_ptr<WinrtTun> tun_;
    std::shared_ptr<WinrtPacketCounters> counters_;
    Socket::Receiver link_receive_;
    std::mutex input_mutex_; // Protects snapshots used by plugin callbacks.
};
} // namespace Partout
