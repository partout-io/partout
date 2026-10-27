// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include "io_types.h"
#include "socket.h"
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.Vpn.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <memory>
#include <atomic>

namespace Partout {
class RuntimeLoop;

// Lifecycle and writes run on the native command worker. StopWrites is atomic.
// Receive callbacks only enqueue borrowed input and must not reenter TUN APIs.
class Tun {
    class State;
    friend class TunnelController;

  public:
    explicit Tun(std::shared_ptr<State> state);
    ~Tun() noexcept;
    Tun(const Tun &) = delete;
    Tun &operator=(const Tun &) = delete;

    bool SetOnReceive(TunOnReceive callback, void *context);
    int32_t Write(const uint8_t *bytes, size_t length);
    void StopWrites();

  private:
    std::shared_ptr<State> state_;
    TunOnReceive callback_ = nullptr;
    void *context_ = nullptr;
    std::atomic<bool> writes_stopped_{false};
};

// Association, Open and Close run on the same native worker. Destruction follows
// daemon shutdown. Native receives share Tun's gate.
class TunnelController : public std::enable_shared_from_this<TunnelController> {
  public:
    explicit TunnelController(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    ~TunnelController();
    TunnelController(const TunnelController &) = delete;
    TunnelController &operator=(const TunnelController &) = delete;

    bool Associate(Socket &socket) noexcept;
    void BindLoop(std::shared_ptr<RuntimeLoop>);

    std::shared_ptr<RuntimeLoop> Loop() const {
        return loop_;
    }

    std::unique_ptr<Tun> Open(const char *info_json);
    void Close() noexcept;
    void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

  private:
    void AssociateUnconnected(Socket &socket);
    std::shared_ptr<RuntimeLoop> loop_;

    std::shared_ptr<Tun::State> state_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket idle_transport_{nullptr};
    winrt::Windows::Networking::Connectivity::NetworkAdapter udp_adapter_{nullptr};
    bool started_ = false;
    Socket *socket_ = nullptr; // Borrowed until Open takes over; the link owns it.
};

} // namespace Partout
