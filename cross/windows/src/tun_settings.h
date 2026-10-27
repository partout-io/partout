// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <cstdint>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Vpn.h>

namespace Partout {

// Validated channel settings from negotiated IP/DNS modules.
class TunSettings {
  public:
    explicit TunSettings(const char *json);

    const auto &IPv4() const {
        return ipv4_;
    }

    const auto &IPv6() const {
        return ipv6_;
    }

    const auto &Routes() const {
        return routes_;
    }

    const auto &Domains() const {
        return domains_;
    }

    uint32_t MTU() const {
        return mtu_;
    }

    uint32_t MaxFrame() const;

  private:
    using JsonObject = winrt::Windows::Data::Json::JsonObject;
    using JsonArray = winrt::Windows::Data::Json::JsonArray;
    using HostName = winrt::Windows::Networking::HostName;
    using HostNameType = winrt::Windows::Networking::HostNameType;
    using VpnRoute = winrt::Windows::Networking::Vpn::VpnRoute;
    using RouteList = winrt::Windows::Foundation::Collections::IVector<VpnRoute>;

    void ApplyIP(const JsonObject &settings);
    void ApplyAddresses(const JsonObject &settings, HostNameType family);
    void ApplyDNS(const JsonObject &settings);
    void ApplyMTU(double mtu);
    void Validate() const;

    static bool Has(const JsonObject &object, const wchar_t *key);
    static JsonArray ReadArray(const JsonObject &object, const wchar_t *key);
    static HostName ParseAddress(const winrt::hstring &text, HostNameType family);
    static VpnRoute ParseSubnet(const winrt::hstring &text, HostNameType family, bool network);
    static RouteList ReadRoutes(const JsonArray &settings, RouteList routes, HostNameType family,
                                bool included);

    winrt::Windows::Foundation::Collections::IVector<HostName> ipv4_ =
        winrt::single_threaded_vector<HostName>();
    winrt::Windows::Foundation::Collections::IVector<HostName> ipv6_ =
        winrt::single_threaded_vector<HostName>();
    winrt::Windows::Networking::Vpn::VpnRouteAssignment routes_;
    winrt::Windows::Networking::Vpn::VpnDomainNameAssignment domains_;
    uint32_t mtu_ = 1400;
    static constexpr uint32_t encapsulation_headroom = 100;
};

} // namespace Partout
