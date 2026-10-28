// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include <ws2tcpip.h>
#include "tun_settings.h"
#include "winrt/log.h"
#include "models/TunnelRemoteInfoWrapper.h"
#include <charconv>
#include <stdexcept>
#include <string>

using namespace winrt;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Vpn;

namespace Partout {

TunSettings::TunSettings(const char *json) {
    if (!json) throw hresult_invalid_argument(L"Missing negotiated tunnel settings");
    try {
        const auto info = Models::TunnelRemoteInfoWrapper::FromJson(nlohmann::json::parse(json));
        if (info.modules) {
            for (const auto &entry : *info.modules) {
                if (const auto *ip = std::get_if<Models::TaggedModuleIp>(&entry))
                    ApplyIP(ip->value);
                else if (const auto *dns = std::get_if<Models::TaggedModuleDns>(&entry))
                    ApplyDNS(dns->value);
            }
        }
    } catch (const nlohmann::json::exception &) {
        throw hresult_invalid_argument(L"Invalid negotiated tunnel settings");
    } catch (const std::logic_error &) {
        throw hresult_invalid_argument(L"Invalid negotiated tunnel settings");
    }
    Validate();
}

uint32_t TunSettings::MaxFrame() const {
    return mtu_ + encapsulation_headroom;
}

void TunSettings::ApplyIP(const Models::IPModule &settings) {
    if (settings.ipv4) ApplyAddresses(*settings.ipv4, HostNameType::Ipv4);
    if (settings.ipv6) ApplyAddresses(*settings.ipv6, HostNameType::Ipv6);
    if (settings.mtu) ApplyMTU(*settings.mtu);
}

void TunSettings::ApplyAddresses(const Models::IPSettings &settings, HostNameType family) {
    const bool v4 = family == HostNameType::Ipv4;
    const auto &addresses = v4 ? ipv4_ : ipv6_;
    for (const auto &subnet : settings.subnets)
        addresses.Append(ParseSubnet(to_hstring(subnet), family, false).Address());

    if (v4) {
        routes_.Ipv4InclusionRoutes(
            ReadRoutes(settings.includedRoutes, routes_.Ipv4InclusionRoutes(), family, true));
        routes_.Ipv4ExclusionRoutes(
            ReadRoutes(settings.excludedRoutes, routes_.Ipv4ExclusionRoutes(), family, false));
    } else {
        routes_.Ipv6InclusionRoutes(
            ReadRoutes(settings.includedRoutes, routes_.Ipv6InclusionRoutes(), family, true));
        routes_.Ipv6ExclusionRoutes(
            ReadRoutes(settings.excludedRoutes, routes_.Ipv6ExclusionRoutes(), family, false));
    }
}

void TunSettings::ApplyDNS(const Models::DNSModule &settings) {
    if (!std::holds_alternative<Models::DNSModuleProtocolTypeCleartext>(settings.protocolType))
        throw hresult_not_implemented(
            L"Encrypted DNS is not supported by the VPN channel settings");

    const auto servers = single_threaded_vector<HostName>();
    for (const auto &server : settings.servers) {
        const HostName host{to_hstring(server)};
        if (host.Type() != HostNameType::Ipv4 && host.Type() != HostNameType::Ipv6)
            throw hresult_invalid_argument(L"DNS servers must be IP addresses");
        servers.Append(host);
    }
    const auto domains = domains_.DomainNameList();
    domains.Clear();
    if (servers.Size() == 0) return;

    const auto names = settings.searchDomains.value_or(std::vector<std::string>{});
    const auto policy = settings.domainPolicy
        ? settings.domainPolicy->value
        : Models::DNSModuleDomainPolicy::INVALID_VALUE_OPENAPI_GENERATED;
    const bool match = policy == Models::DNSModuleDomainPolicy::match ||
        policy == Models::DNSModuleDomainPolicy::matchAndSearch;
    const auto proxies = single_threaded_vector<HostName>();
    if (match && !names.empty()) {
        for (const auto &name : names)
            domains.Append(
                VpnDomainNameInfo{to_hstring(name), VpnDomainNameType::Suffix, servers, proxies});
    } else {
        domains.Append(VpnDomainNameInfo{L".", VpnDomainNameType::Suffix, servers, proxies});
    }
    if (settings.domainName)
        domains.Append(VpnDomainNameInfo{to_hstring(*settings.domainName),
                                         VpnDomainNameType::Suffix, servers, proxies});
    if (!names.empty() && policy != Models::DNSModuleDomainPolicy::match)
        winrt_log(
            WinrtLogNotice,
            "Partout::TunSettings: DNS search suffixes unsupported; DNS resolution rules applied");
}

void TunSettings::ApplyMTU(int32_t mtu) {
    // Zero requests the platform default, preserving any earlier explicit MTU.
    if (mtu == 0) return;
    if (mtu < 68 || mtu > static_cast<int32_t>(65535 - encapsulation_headroom))
        throw hresult_invalid_argument(L"Invalid negotiated MTU");
    mtu_ = static_cast<uint32_t>(mtu);
}

void TunSettings::Validate() const {
    if (ipv4_.Size() == 0 && ipv6_.Size() == 0)
        throw hresult_invalid_argument(L"No negotiated tunnel addresses");
    if (ipv6_.Size() && mtu_ < 1280)
        throw hresult_invalid_argument(L"IPv6 requires an MTU of at least 1280");
}

TunSettings::HostName TunSettings::ParseAddress(const hstring &text, HostNameType family) {
    const HostName host{text};
    if (host.Type() != family)
        throw hresult_invalid_argument(L"Tunnel address has the wrong IP family");
    return host;
}

TunSettings::VpnRoute TunSettings::ParseSubnet(const hstring &text, HostNameType family,
                                               bool network) {
    auto raw = to_string(text);
    const auto slash = raw.find('/');
    const uint32_t bits = family == HostNameType::Ipv4 ? 32 : 128;
    uint32_t prefix = bits;
    if (slash != std::string::npos) {
        const auto end = raw.data() + raw.size();
        const auto parsed = std::from_chars(raw.data() + slash + 1, end, prefix);
        if (parsed.ec != std::errc{} || parsed.ptr != end || prefix > bits)
            throw hresult_invalid_argument(L"Invalid tunnel prefix length");
        raw.resize(slash);
    }
    const auto host = ParseAddress(to_hstring(raw), family);
    if (!network) return VpnRoute{host, static_cast<uint8_t>(prefix)};

    const int af = family == HostNameType::Ipv4 ? AF_INET : AF_INET6;
    uint8_t bytes[16]{};
    if (InetPtonW(af, host.CanonicalName().c_str(), bytes) != 1) throw hresult_invalid_argument();
    for (uint32_t bit = prefix; bit < bits; ++bit)
        bytes[bit / 8] &= static_cast<uint8_t>(~(0x80u >> (bit % 8)));
    wchar_t address[INET6_ADDRSTRLEN]{};
    if (!InetNtopW(af, bytes, address, INET6_ADDRSTRLEN)) throw hresult_invalid_argument();
    return VpnRoute{HostName{address}, static_cast<uint8_t>(prefix)};
}

TunSettings::RouteList TunSettings::ReadRoutes(const std::vector<Models::Route> &settings, RouteList routes,
                                               HostNameType family, bool included) {
    if (!routes) routes = single_threaded_vector<VpnRoute>();
    const bool v4 = family == HostNameType::Ipv4;
    for (const auto &route : settings) {
        // Windows routes select an interface, not a per-route gateway.
        if (route.gateway) ParseAddress(to_hstring(*route.gateway), family);
        const auto destination =
            ParseSubnet(route.destination ? to_hstring(*route.destination)
                                          : hstring{v4 ? L"0.0.0.0/0" : L"::/0"},
                        family, true);
        if (!included || destination.PrefixSize() != 0) {
            routes.Append(destination);
            continue;
        }
        // Override the physical default by prefix length, regardless of interface metrics.
        routes.Append(ParseSubnet(v4 ? L"0.0.0.0/1" : L"::/1", family, true));
        routes.Append(ParseSubnet(v4 ? L"128.0.0.0/1" : L"8000::/1", family, true));
    }
    return routes;
}

} // namespace Partout
