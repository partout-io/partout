// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include <winrt/Windows.Networking.Vpn.h>
#include "winrt/tun.h"
#include <functional>
#include <memory>
#include <mutex>

struct WinrtTun;

// Internal platform ref. Daemon bindings retain the channel until callbacks drain.
class PartoutTunnelController {
public:
    explicit PartoutTunnelController(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    ~PartoutTunnelController();
    PartoutTunnelController(const PartoutTunnelController &) = delete;
    PartoutTunnelController &operator=(const PartoutTunnelController &) = delete;

    bool Associate(winrt_socket socket) noexcept;
    bool Start(const char *info_json) noexcept;
    void Stop() noexcept;
    winrt_tun Open(const char *info_json);
    void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

private:
    winrt::Windows::Networking::Vpn::VpnChannel channel_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    bool started_ = false;
    winrt_socket socket_ = nullptr; // Borrowed until Start; the link owns it.
    std::shared_ptr<WinrtTun> tun_;
    std::function<void(const uint8_t *, size_t)> link_receive_;
    std::mutex input_mutex_; // Protects snapshots used by plugin callbacks.
};
