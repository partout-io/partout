// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <cstdint>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Vpn.h>

namespace Partout {

// Only negotiated IP/DNS modules are consumed. No protocol or portable ABI dependency.
class TunSettings {
public:
    winrt::Windows::Foundation::Collections::IVector<winrt::Windows::Networking::HostName> ipv4 =
        winrt::single_threaded_vector<winrt::Windows::Networking::HostName>();
    winrt::Windows::Foundation::Collections::IVector<winrt::Windows::Networking::HostName> ipv6 =
        winrt::single_threaded_vector<winrt::Windows::Networking::HostName>();
    winrt::Windows::Networking::Vpn::VpnRouteAssignment routes;
    winrt::Windows::Networking::Vpn::VpnDomainNameAssignment domains;
    uint32_t mtu = 1400;
    static constexpr uint32_t encapsulation_headroom = 100;

    uint32_t maxFrame() const;
    static TunSettings parse(const char *text);
};
}
