// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "../../../cross/windows/src/models/ABIEnvelope.h"
#include "../../../cross/windows/src/models/ConnectionStatus.h"
#include "../../../cross/windows/src/models/CryptoBackend.h"
#include "../../../cross/windows/src/models/DataCount.h"
#include "../../../cross/windows/src/models/ModuleImportContext.h"
#include "../../../cross/windows/src/models/OpenVpnObfuscationMethod.h"
#include "../../../cross/windows/src/models/TunnelRemoteInfoWrapper.h"
#include <cassert>
#include <cstdio>
#include <utility>

using namespace Partout::Models;
using nlohmann::json;

template<typename T>
T ExpectRoundTrip(const json &source) {
    const auto value = source.get<T>();
    std::stringstream errors;
    assert(ValidateModel(value, errors, ""));
    assert(json(value) == source);
    assert(json(source.get<T>()) == source);
    return value;
}

template<typename Operation>
void ExpectFailure(Operation operation) {
    bool failed = false;
    try {
        operation();
    } catch (const std::exception &) {
        failed = true;
    }
    assert(failed);
}

template<typename Union, typename Alternative>
void ExpectAlternative(const char *source) {
    const auto value = ExpectRoundTrip<Union>(json::parse(source));
    assert(std::holds_alternative<Alternative>(value));
}

int main() {
    ExpectRoundTrip<ConnectionStatus>("connected");
    // The daemon's callback sends a raw token, not a quoted JSON string.
    static_assert(noexcept(TryReadStringEnum<ConnectionStatus>(nullptr)));
    for (const auto &test : {
        std::pair{"disconnected", ConnectionStatus::disconnected},
        std::pair{"connecting", ConnectionStatus::connecting},
        std::pair{"connected", ConnectionStatus::connected},
        std::pair{"disconnecting", ConnectionStatus::disconnecting}
    }) {
        const auto status = TryReadStringEnum<ConnectionStatus>(test.first);
        assert(status && status->value == test.second);
    }
    for (const auto *token : {static_cast<const char *>(nullptr), "", "unknown", "CONNECTED",
                              "\"connected\"", "null", "{}"}) {
        assert(!TryReadStringEnum<ConnectionStatus>(token));
    }
    ExpectRoundTrip<CryptoBackend>(4);
    ExpectFailure([] {
        (void)json("unknown").get<ConnectionStatus>();
    });
    ExpectFailure([] {
        (void)json(1.5).get<CryptoBackend>();
    });

    const auto ip = json::parse(R"({"id":"ip","mtu":1400,"ipv4":{
        "subnets":["10.8.0.2/24"],"includedRoutes":[{}],"excludedRoutes":[]}})");
    const json tagged = {{"type", "IP"}, {"value", ip}};
    const auto module = ExpectRoundTrip<TaggedModule>(tagged);
    assert(std::get<TaggedModuleIp>(module).value.mtu == 1400);
    assert(!std::get<TaggedModuleIp>(module).value.ipv6);
    assert(!std::get<TaggedModuleIp>(module).value.ipv4->includedRoutes.front().destination);
    TaggedModuleIp constructed{};
    constructed.value.id = "constructed";
    assert(json(TaggedModule{constructed}) == json({{"type", "IP"}, {"value", {{"id", "constructed"}}}}));
    constructed.type = "DNS";
    ExpectFailure([&constructed] {
        (void)json(TaggedModule{constructed});
    });
    ExpectFailure([] {
        (void)json::parse(R"({"type":"DNS","value":{"id":"ip"}})").get<TaggedModuleIp>();
    });
    ExpectAlternative<TaggedModule, TaggedModuleCustom>(
        R"({"type":"Custom","value":{"innerType":"Undefined","json":{}}})");
    ExpectAlternative<TaggedModule, TaggedModuleHTTPProxy>(
        R"({"type":"HTTPProxy","value":{"id":"http","bypassDomains":[]}})");
    ExpectAlternative<TaggedModule, TaggedModuleOnDemand>(
        R"({"type":"OnDemand","value":{"id":"on","policy":"any","withSSIDs":{},"withOtherNetworks":[]}})");
    ExpectAlternative<TaggedModule, TaggedModuleOpenVpn>(R"({"type":"OpenVPN","value":{"id":"vpn"}})");
    ExpectAlternative<TaggedModule, TaggedModuleWireGuard>(R"({"type":"WireGuard","value":{"id":"wg"}})");

    const auto dns = json::parse(R"({"type":"DNS","value":{"id":"dns",
        "protocolType":{"type":"cleartext"},"servers":["10.8.0.1"],
        "searchDomains":["example.org"],"domainPolicy":"matchAndSearch"}})");
    const json profile = {{"id", "profile"}, {"name", "Test"},
        {"modules", {tagged, dns}}, {"activeModulesIds", {"ip"}}};
    ExpectRoundTrip<TaggedProfile>(profile);
    const json source = {{"profile", profile}, {"originalModuleId", "vpn"},
        {"modules", {tagged, dns}}};
    const auto info = ExpectRoundTrip<TunnelRemoteInfoWrapper>(source);
    assert(info.modules && info.modules->size() == 2);
    const auto decodedDNS = std::get<TaggedModuleDns>(info.modules->at(1)).value;
    assert(std::holds_alternative<DNSModuleProtocolTypeCleartext>(decodedDNS.protocolType));
    assert(decodedDNS.domainPolicy->value == DNSModuleDomainPolicy::matchAndSearch);
    assert(!decodedDNS.domainName);

    for (const auto *protocol : {R"({"type":"https","url":"https://dns.example/dns-query"})",
                                 R"({"type":"tls","hostname":"dns.example"})"}) {
        const auto decoded = ExpectRoundTrip<DNSModuleProtocolType>(json::parse(protocol));
        assert(!std::holds_alternative<DNSModuleProtocolTypeCleartext>(decoded));
    }
    const auto context = ExpectRoundTrip<ModuleImportContext>(
        json::parse(R"({"type":"OpenVPN","passphrase":"secret"})"));
    assert(std::holds_alternative<ModuleImportContextOpenVpn>(context));
    ExpectAlternative<ModuleImportContext, ModuleImportContextWireGuard>(R"({"type":"WireGuard"})");
    const auto obfuscation = ExpectRoundTrip<OpenVpnObfuscationMethod>(
        json::parse(R"({"type":"xormask","mask":"secret"})"));
    assert(std::holds_alternative<OpenVpnObfuscationMethodXormask>(obfuscation));
    ExpectAlternative<OpenVpnObfuscationMethod, OpenVpnObfuscationMethodObfuscate>(
        R"({"type":"obfuscate","mask":"secret"})");
    ExpectAlternative<OpenVpnObfuscationMethod, OpenVpnObfuscationMethodReverse>(R"({"type":"reverse"})");
    ExpectAlternative<OpenVpnObfuscationMethod, OpenVpnObfuscationMethodXorptrpos>(R"({"type":"xorptrpos"})");

    for (const auto *invalid : {R"({"value":{"id":"ip"}})", R"({"type":42,"value":{}})",
         R"({"type":"FutureModule","value":{}})", R"({"type":"IP","value":{}})",
         R"({"type":"DNS","value":{"id":"dns","protocolType":{"type":"unknown"},"servers":[]}})"}) {
        ExpectFailure([invalid] {
            (void)json::parse(invalid).get<TaggedModule>();
        });
    }
    for (const auto &mtu : json::array({1300.5, 4294968796LL, -2147483649LL, "1400", true})) {
        auto invalid = tagged;
        invalid["value"]["mtu"] = mtu;
        ExpectFailure([&invalid] {
            (void)invalid.get<TaggedModule>();
        });
    }
    assert(IPModule::FromJson(json::parse(R"({"id":"ip","mtu":1400.0})")).mtu == 1400);
    const auto absent = IPModule::FromJson(json::parse(R"({"id":"ip","mtu":null,"ipv4":null})"));
    assert(!absent.mtu && !absent.ipv4);
    assert(json(absent) == json({{"id", "ip"}}));
    const auto route = Route::FromJson(json::parse(R"({"destination":"","gateway":null})"));
    assert(route.destination && route.destination->empty() && !route.gateway);
    ExpectFailure([] {
        (void)json(42).get<Route>();
    });

    // Reusing a destination clears old optionals; failed decoding is transactional.
    auto reused = ip.get<IPModule>();
    json({{"id", "replacement"}}).get_to(reused);
    assert(reused.id == "replacement" && !reused.ipv4 && !reused.mtu);
    ExpectFailure([&reused] {
        json({{"id", "invalid"}, {"mtu", 1.5}}).get_to(reused);
    });
    assert(reused.id == "replacement" && !reused.mtu);
    ExpectRoundTrip<DataCount>(json::parse(R"({"received":9223372036854775807,"sent":0})"));
    ExpectFailure([] {
        (void)json::parse(R"({"received":9223372036854775808,"sent":0})").get<DataCount>();
    });

    ExpectRoundTrip<OnDemandModule>(json::parse(R"({"id":"on-demand","policy":"any",
        "withSSIDs":{"home":true,"office":false},"withOtherNetworks":["mobile","ethernet"]})"));
    for (const auto &payload : json::array({json::object(), json::array({1, 2}), "text", 7, true, nullptr})) {
        const json envelope = {{"payload", payload}};
        const auto value = ExpectRoundTrip<ABIEnvelope>(envelope);
        assert(value.payload && *value.payload == payload);
    }
    std::puts("C++ generated discriminator and optional-field tests passed");
}
