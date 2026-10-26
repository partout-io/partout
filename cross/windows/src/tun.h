// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include "winrt/tun.h"
#include "socket.h"
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.Vpn.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <memory>

namespace Partout {

// Lifecycle, writes and StopWrites run on the looper (or during quiescent teardown).
// Receive callbacks only enqueue borrowed input and must not reenter TUN APIs.
class Tun {
    class State;
    friend class TunnelController;

public:
    explicit Tun(std::shared_ptr<State> state);
    ~Tun() noexcept;
    Tun(const Tun &) = delete;
    Tun &operator=(const Tun &) = delete;

    bool SetOnReceive(winrt_tun_on_receive callback, void *context);
    int32_t Write(const uint8_t *bytes, size_t length);
    void StopWrites();

private:
    std::shared_ptr<State> state_;
    winrt_tun_on_receive callback_ = nullptr;
    void *context_ = nullptr;
    bool writes_stopped_ = false;
};

// Association may run on the setup worker before Open. Open and Close run on the
// looper; destruction follows daemon shutdown. Native receives share Tun's gate.
class TunnelController {
public:
    explicit TunnelController(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    ~TunnelController();
    TunnelController(const TunnelController &) = delete;
    TunnelController &operator=(const TunnelController &) = delete;

    bool Associate(Socket &socket) noexcept;
    winrt_tun Open(const char *info_json);
    void Close() noexcept;
    void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

private:
    void AssociateUnconnected(Socket &socket);

    std::shared_ptr<Tun::State> state_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket idle_transport_{nullptr};
    winrt::Windows::Networking::Connectivity::NetworkAdapter udp_adapter_{nullptr};
    bool started_ = false;
    Socket *socket_ = nullptr; // Borrowed until Open takes over; the link owns it.
};

} // namespace Partout

// Owned C handle; the TUN stays private to the native implementation.
struct __winrt_tun_struct {
    Partout::Tun handle;
};
