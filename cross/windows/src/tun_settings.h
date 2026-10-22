// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <winsock2.h>
#include <ws2tcpip.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Vpn.h>
#include <charconv>
#include <cmath>
#include "winrt/log.h"

namespace partout::windows {
using namespace winrt;
using namespace Windows::Data::Json;
using namespace Windows::Networking;
using namespace Windows::Networking::Vpn;

// Only negotiated IP/DNS modules are consumed. No protocol or portable ABI dependency.
struct TunnelSettings {
    Windows::Foundation::Collections::IVector<HostName> ipv4 = single_threaded_vector<HostName>();
    Windows::Foundation::Collections::IVector<HostName> ipv6 = single_threaded_vector<HostName>();
    VpnRouteAssignment routes;
    VpnDomainNameAssignment domains;
    uint32_t mtu = 1400;
    static constexpr uint32_t max_frame = 1500;

    static bool has(JsonObject const &object, wchar_t const *key) {
        return object.HasKey(key) && object.GetNamedValue(key).ValueType() != JsonValueType::Null;
    }

    static JsonArray array(JsonObject const &object, wchar_t const *key) {
        return has(object, key) ? object.GetNamedArray(key) : JsonArray{};
    }

    static HostName ip(hstring const &text, HostNameType family) {
        HostName host{text};
        if (host.Type() != family) throw hresult_invalid_argument(L"Tunnel address has the wrong IP family");
        return host;
    }

    static VpnRoute subnet(hstring const &text, HostNameType family, bool network) {
        auto raw = to_string(text);
        const auto slash = raw.find('/');
        uint32_t prefix = family == HostNameType::Ipv4 ? 32 : 128;
        if (slash != std::string::npos) {
            const auto end = raw.data() + raw.size();
            const auto parsed = std::from_chars(raw.data() + slash + 1, end, prefix);
            if (parsed.ec != std::errc{} || parsed.ptr != end || prefix > (family == HostNameType::Ipv4 ? 32u : 128u))
                throw hresult_invalid_argument(L"Invalid tunnel prefix length");
            raw.resize(slash);
        }
        auto host = ip(to_hstring(raw), family);
        if (network) {
            const int af = family == HostNameType::Ipv4 ? AF_INET : AF_INET6;
            uint8_t bytes[16]{};
            if (InetPtonW(af, host.CanonicalName().c_str(), bytes) != 1) throw hresult_invalid_argument();
            for (uint32_t bit = prefix; bit < (af == AF_INET ? 32u : 128u); ++bit)
                bytes[bit / 8] &= static_cast<uint8_t>(~(0x80u >> (bit % 8)));
            wchar_t address[INET6_ADDRSTRLEN]{};
            if (!InetNtopW(af, bytes, address, INET6_ADDRSTRLEN)) throw hresult_invalid_argument();
            host = HostName{address};
        }
        return VpnRoute{host, static_cast<uint8_t>(prefix)};
    }

    void applyIP(JsonObject const &settings, HostNameType family) {
        const bool v4 = family == HostNameType::Ipv4;
        auto addresses = v4 ? ipv4 : ipv6;
        for (const auto &value : array(settings, L"subnets"))
            addresses.Append(subnet(value.GetString(), family, false).Address());
        const auto readRoutes = [&](wchar_t const *key, Windows::Foundation::Collections::IVector<VpnRoute> result) {
            if (!result) result = single_threaded_vector<VpnRoute>();
            for (const auto &value : array(settings, key)) {
                const auto route = value.GetObject();
                // Windows routes select an interface, not a per-route gateway.
                if (has(route, L"gateway")) ip(route.GetNamedString(L"gateway"), family);
                result.Append(subnet(has(route, L"destination") ? route.GetNamedString(L"destination") :
                    hstring{v4 ? L"0.0.0.0/0" : L"::/0"}, family, true));
            }
            return result;
        };
        if (v4) {
            routes.Ipv4InclusionRoutes(readRoutes(L"includedRoutes", routes.Ipv4InclusionRoutes()));
            routes.Ipv4ExclusionRoutes(readRoutes(L"excludedRoutes", routes.Ipv4ExclusionRoutes()));
        } else {
            routes.Ipv6InclusionRoutes(readRoutes(L"includedRoutes", routes.Ipv6InclusionRoutes()));
            routes.Ipv6ExclusionRoutes(readRoutes(L"excludedRoutes", routes.Ipv6ExclusionRoutes()));
        }
    }

    void applyDNS(JsonObject const &settings) {
        if (has(settings, L"protocolType") && settings.GetNamedObject(L"protocolType").GetNamedString(L"type") != L"cleartext")
            throw hresult_not_implemented(L"Encrypted DNS is not supported by the VPN channel settings");
        auto servers = single_threaded_vector<HostName>();
        for (const auto &value : array(settings, L"servers")) {
            HostName host{value.GetString()};
            if (host.Type() != HostNameType::Ipv4 && host.Type() != HostNameType::Ipv6)
                throw hresult_invalid_argument(L"DNS servers must be IP addresses");
            servers.Append(host);
        }
        domains.DomainNameList().Clear();
        if (servers.Size() == 0) return;
        auto names = array(settings, L"searchDomains");
        const auto policy = settings.GetNamedString(L"domainPolicy", L"");
        const bool match = policy == L"match" || policy == L"matchAndSearch";
        const auto proxies = single_threaded_vector<HostName>();
        const auto append = [&](hstring const &name) {
            domains.DomainNameList().Append(VpnDomainNameInfo{name, VpnDomainNameType::Suffix, servers, proxies});
        };
        if (!match || names.Size() == 0) append(L".");
        else for (const auto &value : names) append(value.GetString());
        if (has(settings, L"domainName")) append(settings.GetNamedString(L"domainName"));
        if (names.Size() && policy != L"match")
            winrt_log(WinrtLogNotice, "VPN channel cannot configure DNS search suffixes; DNS resolution rules are applied");
    }

    static TunnelSettings parse(const char *text) {
        if (!text) throw hresult_invalid_argument(L"Missing negotiated tunnel settings");
        const auto root = JsonObject::Parse(to_hstring(text));
        TunnelSettings result;
        for (const auto &entry : root.GetNamedArray(L"modules")) {
            const auto module = entry.GetObject();
            const auto type = module.GetNamedString(L"type");
            if (type != L"IP" && type != L"DNS") continue;
            const auto value = module.GetNamedObject(L"value");
            if (type == L"DNS") { result.applyDNS(value); continue; }
            if (has(value, L"ipv4")) result.applyIP(value.GetNamedObject(L"ipv4"), HostNameType::Ipv4);
            if (has(value, L"ipv6")) result.applyIP(value.GetNamedObject(L"ipv6"), HostNameType::Ipv6);
            if (has(value, L"mtu")) {
                const double mtu = value.GetNamedNumber(L"mtu");
                if (!std::isfinite(mtu) || mtu != std::floor(mtu) || mtu < 68 || mtu > 65535)
                    throw hresult_invalid_argument(L"Invalid negotiated MTU");
                result.mtu = static_cast<uint32_t>(mtu);
                if (result.mtu > 1400) {
                    winrt_log(WinrtLogNotice, "VPN channel MTU capped from %u to 1400", result.mtu);
                    result.mtu = 1400;
                }
            }
        }
        if (result.ipv4.Size() == 0 && result.ipv6.Size() == 0)
            throw hresult_invalid_argument(L"No negotiated tunnel addresses");
        if (result.ipv6.Size() && result.mtu < 1280)
            throw hresult_invalid_argument(L"IPv6 requires an MTU of at least 1280");
        return result;
    }
};
}
