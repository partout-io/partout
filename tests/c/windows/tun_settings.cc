// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "../../../cross/windows/src/tun_settings.h"
#include <cassert>
#include <cstdio>

using partout::windows::TunnelSettings;

int main() try {
    winrt::init_apartment();
    const auto settings = TunnelSettings::parse(R"({"modules":[
        {"type":"IP","value":{"mtu":1500,
            "ipv4":{"subnets":["10.8.0.2/24"],
                "includedRoutes":[{}, {"destination":"192.168.1.7/24","gateway":"10.8.0.1"}],
                "excludedRoutes":[{"destination":"192.0.2.9/32"}]},
            "ipv6":{"subnets":["fd00::2/64"],
                "includedRoutes":[{"destination":"::/0"}],
                "excludedRoutes":[{"destination":"fd01::7/64"}]}}},
        {"type":"DNS","value":{"protocolType":{"type":"cleartext"},
            "servers":["10.8.0.1","fd00::1"],"searchDomains":["example.org"],"domainPolicy":"match"}}
    ]})");
    assert(settings.ipv4.GetAt(0).CanonicalName() == L"10.8.0.2");
    assert(settings.ipv6.GetAt(0).CanonicalName() == L"fd00::2");
    assert(settings.mtu == 1400);
    const auto routes = settings.routes.Ipv4InclusionRoutes();
    assert(routes.Size() == 2 && routes.GetAt(0).PrefixSize() == 0);
    assert(routes.GetAt(1).Address().CanonicalName() == L"192.168.1.0");
    assert(routes.GetAt(1).PrefixSize() == 24);
    assert(settings.routes.Ipv4ExclusionRoutes().GetAt(0).PrefixSize() == 32);
    assert(settings.routes.Ipv6InclusionRoutes().GetAt(0).PrefixSize() == 0);
    assert(settings.routes.Ipv6ExclusionRoutes().GetAt(0).Address().CanonicalName() == L"fd01::");
    const auto domains = settings.domains.DomainNameList();
    assert(domains.Size() == 1 && domains.GetAt(0).DomainName().CanonicalName() == L"example.org");
    assert(domains.GetAt(0).DnsServers().Size() == 2);
    assert(domains.GetAt(0).WebProxyServers() && domains.GetAt(0).WebProxyServers().Size() == 0);

    const auto v4 = TunnelSettings::parse(R"({"modules":[
        {"type":"IP","value":{"ipv4":{"subnets":["10.8.0.2"]},"mtu":1300}},
        {"type":"DNS","value":{"servers":["10.8.0.1"]}}
    ]})");
    assert(v4.ipv6.Size() == 0 && v4.mtu == 1300);
    assert(v4.domains.DomainNameList().Size() == 1); // The catch-all rule has a null DomainName.
    assert(v4.domains.DomainNameList().GetAt(0).WebProxyServers());
    const auto v6 = TunnelSettings::parse(R"({"modules":[
        {"type":"IP","value":{"ipv6":{"subnets":["fd00::2/128"]}}}
    ]})");
    assert(v6.ipv4.Size() == 0 && v6.ipv6.Size() == 1);

    for (const auto json : {
        R"({"modules":[]})",
        R"({"modules":[{"type":"IP","value":{"ipv4":{"subnets":["fd00::2/64"]}}}]})",
        R"({"modules":[{"type":"IP","value":{"ipv4":{"subnets":["10.8.0.2/33"]}}}]})",
        R"({"modules":[{"type":"IP","value":{"ipv6":{"subnets":["fd00::2"]},"mtu":1200}}]})",
        R"({"modules":[{"type":"IP","value":{"ipv4":{"subnets":["10.8.0.2"]},"mtu":1300.5}}]})",
        R"({"modules":[{"type":"DNS","value":{"protocolType":{"type":"https"}}}]})"
    }) {
        bool rejected = false;
        try { TunnelSettings::parse(json); }
        catch (winrt::hresult_error const &) { rejected = true; }
        assert(rejected);
    }
    puts("Tunnel settings tests passed");
} catch (winrt::hresult_error const &error) {
    fprintf(stderr, "HRESULT 0x%08x: %s\n", static_cast<unsigned>(error.code().value),
        winrt::to_string(error.message()).c_str());
    return 1;
}
