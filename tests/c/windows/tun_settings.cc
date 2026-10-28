// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "../../../cross/windows/src/tun_settings.h"
#include <nlohmann/json.hpp>
#include <cassert>
#include <cstdio>

using Partout::TunSettings;

// Add common ABI metadata while retaining invalid payloads for error tests.
TunSettings Settings(const char *json) {
    if (!json) return TunSettings(nullptr);
    auto info = nlohmann::json::parse(json);
    info["profile"] = {{"id", "profile"}, {"name", "Test"},
        {"modules", nlohmann::json::array()}, {"activeModulesIds", nlohmann::json::array()}};
    info["originalModuleId"] = "vpn";
    const auto encoded = info.dump();
    return TunSettings(encoded.c_str());
}

int main() try {
    winrt::init_apartment();
    const auto settings = Settings(R"({"modules":[
        {"type":"IP","value":{"id":"ip","mtu":1500,
            "ipv4":{"subnets":["10.8.0.2/24"],
                "includedRoutes":[{}, {"destination":"192.168.1.7/24","gateway":"10.8.0.1"}],
                "excludedRoutes":[{"destination":"192.0.2.9/32"}]},
            "ipv6":{"subnets":["fd00::2/64"],
                "includedRoutes":[{"destination":"::/0"}],
                "excludedRoutes":[{"destination":"fd01::7/64"}]}}},
        {"type":"DNS","value":{"id":"dns","protocolType":{"type":"cleartext"},
            "servers":["10.8.0.1","fd00::1"],"searchDomains":["example.org"],"domainPolicy":"match"}}
    ]})");
    assert(settings.IPv4().GetAt(0).CanonicalName() == L"10.8.0.2");
    assert(settings.IPv6().GetAt(0).CanonicalName() == L"fd00::2");
    assert(settings.MTU() == 1500 && settings.MaxFrame() == 1600);
    const auto routes = settings.Routes().Ipv4InclusionRoutes();
    assert(routes.Size() == 3);
    assert(routes.GetAt(0).PrefixSize() == 1 &&
           routes.GetAt(0).Address().CanonicalName() == L"0.0.0.0");
    assert(routes.GetAt(1).PrefixSize() == 1 &&
           routes.GetAt(1).Address().CanonicalName() == L"128.0.0.0");
    assert(routes.GetAt(2).Address().CanonicalName() == L"192.168.1.0");
    assert(routes.GetAt(2).PrefixSize() == 24);
    assert(settings.Routes().Ipv4ExclusionRoutes().GetAt(0).PrefixSize() == 32);
    const auto v6routes = settings.Routes().Ipv6InclusionRoutes();
    assert(v6routes.Size() == 2);
    assert(v6routes.GetAt(0).PrefixSize() == 1 &&
           v6routes.GetAt(0).Address().CanonicalName() == L"::");
    assert(v6routes.GetAt(1).PrefixSize() == 1 &&
           v6routes.GetAt(1).Address().CanonicalName() == L"8000::");
    assert(settings.Routes().Ipv6ExclusionRoutes().GetAt(0).Address().CanonicalName() == L"fd01::");
    const auto domains = settings.Domains().DomainNameList();
    assert(domains.Size() == 1 && domains.GetAt(0).DomainName().CanonicalName() == L"example.org");
    assert(domains.GetAt(0).DnsServers().Size() == 2);
    assert(domains.GetAt(0).WebProxyServers() && domains.GetAt(0).WebProxyServers().Size() == 0);

    const auto v4 = Settings(R"({"modules":[
        {"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["10.8.0.2"]},"mtu":1300}},
        {"type":"DNS","value":{"id":"dns","protocolType":{"type":"cleartext"},"servers":["10.8.0.1"]}}
    ]})");
    assert(v4.IPv6().Size() == 0 && v4.MTU() == 1300 && v4.MaxFrame() == 1400);
    assert(v4.Domains().DomainNameList().Size() == 1); // The catch-all rule has a null DomainName.
    assert(v4.Domains().DomainNameList().GetAt(0).WebProxyServers());
    const auto v6 = Settings(R"({"modules":[
        {"type":"IP","value":{"id":"ip","ipv6":{"includedRoutes":[],"excludedRoutes":[],"subnets":["fd00::2/128"]}}}
    ]})");
    assert(v6.IPv4().Size() == 0 && v6.IPv6().Size() == 1);
    assert(v6.MTU() == 1400 && v6.MaxFrame() == 1500);

    const auto automatic =
        R"({"modules":[{"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["10.8.0.2"]},"mtu":0}}]})";
    assert(Settings(automatic).MTU() == 1400);
    assert(Settings(automatic).MaxFrame() == 1500);

    // Multiple IP modules accumulate addresses and routes; zero preserves an explicit MTU.
    const auto combined = Settings(R"({"modules":[
        {"type":"IP","value":{"id":"ip","ipv4":{"excludedRoutes":[],"subnets":["10.8.0.2/24"],"includedRoutes":[{}]},"mtu":1300}},
        {"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"subnets":["10.8.0.3/24"],"excludedRoutes":[{}]},"mtu":0}},
        {"type":"Custom","value":{"innerType":"Undefined","json":{}}}
    ]})");
    assert(combined.IPv4().Size() == 2 && combined.MTU() == 1300);
    assert(combined.Routes().Ipv4InclusionRoutes().Size() == 2);
    const auto excluded = combined.Routes().Ipv4ExclusionRoutes();
    assert(excluded.Size() == 1 && excluded.GetAt(0).PrefixSize() == 0);

    const auto matchingDNS = Settings(R"({"modules":[
        {"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["10.8.0.2"]}}},
        {"type":"DNS","value":{"id":"dns","protocolType":{"type":"cleartext"},"servers":["10.8.0.1"],"searchDomains":["one.example","two.example"],
            "domainPolicy":"matchAndSearch","domainName":"three.example"}}
    ]})");
    const auto matched = matchingDNS.Domains().DomainNameList();
    assert(matched.Size() == 3);
    assert(matched.GetAt(0).DomainName().CanonicalName() == L"one.example");
    assert(matched.GetAt(2).DomainName().CanonicalName() == L"three.example");

    const auto clearedDNS = Settings(R"({"modules":[
        {"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["10.8.0.2"]}}},
        {"type":"DNS","value":{"id":"dns","protocolType":{"type":"cleartext"},"servers":["10.8.0.1"]}},
        {"type":"DNS","value":{"id":"dns","protocolType":{"type":"cleartext"},"servers":[]}}
    ]})");
    assert(clearedDNS.Domains().DomainNameList().Size() == 0);

    for (const auto json :
         {static_cast<const char *>(nullptr), R"({"modules":[]})",
          R"({"modules":[{"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["10.8.0.2"]},"mtu":-1}}]})",
          R"({"modules":[{"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["fd00::2/64"]}}}]})",
          R"({"modules":[{"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["10.8.0.2/33"]}}}]})",
          R"({"modules":[{"type":"IP","value":{"id":"ip","ipv6":{"includedRoutes":[],"excludedRoutes":[],"subnets":["fd00::2"]},"mtu":1200}}]})",
          R"({"modules":[{"type":"IP","value":{"id":"ip","ipv4":{"includedRoutes":[],"excludedRoutes":[],"subnets":["10.8.0.2"]},"mtu":1300.5}}]})",
          R"({"modules":[{"type":"IP","value":{"id":"ip","mtu":4294968796}}]})",
          R"({"modules":[{"type":"unknown","value":{}}]})",
          R"({"modules":[{"type":"DNS","value":{"id":"dns","servers":[],"protocolType":{"type":"https","url":"https://dns.example/dns-query"}}}]})"}) {
        bool rejected = false;
        try {
            const auto rejected_settings = Settings(json);
        } catch (winrt::hresult_error const &) {
            rejected = true;
        }
        assert(rejected);
    }
    for (const auto *json : {"{", R"({"modules":[]})"}) {
        bool rejected = false;
        try {
            const TunSettings invalid{json};
        } catch (const winrt::hresult_invalid_argument &) {
            rejected = true;
        }
        assert(rejected);
    }
    puts("Tunnel settings tests passed");
} catch (winrt::hresult_error const &error) {

    fprintf(stderr, "HRESULT 0x%08x: %s\n", static_cast<unsigned>(error.code().value),
            winrt::to_string(error.message()).c_str());
    return 1;
}
