// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include "io_types.h"
#include "socket.h"
#include "network.h"
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
    explicit Tun(State &state);
    ~Tun() noexcept;
    Tun(const Tun &) = delete;
    Tun &operator=(const Tun &) = delete;

    // Removing the callback waits for in-flight delivery under the receive mutex.
    bool SetOnReceive(TunOnReceive callback);
    void ReportError(int32_t error);

    int32_t WriteStatus() const {
        return write_status_.load();
    }

    int32_t Write(const uint8_t *bytes, size_t length);
    void StopWrites();

private:
    State &state_; // Borrowed; the controller outlives every TUN handle.
    TunOnReceive callback_ = nullptr;
    std::atomic<int32_t> write_status_{0};
};

// Association, Open and Close run on the same native worker. Destruction follows
// daemon shutdown. Native receives share Tun's gate.
class TunnelController {
public:
    TunnelController(RuntimeLoop &, winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    ~TunnelController();
    TunnelController(const TunnelController &) = delete;
    TunnelController &operator=(const TunnelController &) = delete;

    bool Associate(Socket &socket) noexcept;
    RuntimeLoop &Loop() const { return loop_; }
    NetworkMonitor &Monitor() { return monitor_; }

    std::unique_ptr<Tun> Open(const char *info_json);
    void Close() noexcept;
    void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

private:
    void AssociateUnconnected(Socket &socket);
    RuntimeLoop &loop_; // Runtime closes and destroys the controller before the loop.
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
