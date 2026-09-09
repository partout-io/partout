// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "portable/socket_winrt.h"
#include <winrt/Windows.Networking.Vpn.h>

// Internal platform ref. Daemon bindings retain the channel until callbacks drain.
class PartoutTunnelController {
public:
    explicit PartoutTunnelController(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    ~PartoutTunnelController();
    PartoutTunnelController(const PartoutTunnelController &) = delete;
    PartoutTunnelController &operator=(const PartoutTunnelController &) = delete;

    bool Associate(pp_socket_fd fd) noexcept;
    bool Start(const char *info_json) noexcept;
    void Stop() noexcept;

private:
    winrt::Windows::Networking::Vpn::VpnChannel channel_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    bool started_ = false;
};
