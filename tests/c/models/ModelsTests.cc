// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "../../../cross/cpp/models/ABIEnvelope.h"
#include "../../../cross/cpp/models/ConnectionStatus.h"
#include "../../../cross/cpp/models/CryptoBackend.h"
#include "../../../cross/cpp/models/DataCount.h"
#include "../../../cross/cpp/models/ModuleImportContext.h"
#include "../../../cross/cpp/models/OpenVpnObfuscationMethod.h"
#include "../../../cross/cpp/models/OpenVpnCipher.h"
#include "../../../cross/cpp/models/OpenVpnDigest.h"
#include "../../../cross/cpp/models/TunnelRemoteInfoWrapper.h"
#include <cassert>
#include <cstdio>
#include <utility>

using namespace Partout::Models;
using Partout::Json;
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
    // The public value API preserves unknown fields, nulls, arrays, and copy isolation.
    auto document = Json::Parse(R"({"unknown":{"nested":[null,1,"two"]},"enabled":false})");
    auto copy = document;
    copy.Set("enabled", true);
    assert(!document.At("enabled").Get<bool>());
    assert(copy.At("enabled").Get<bool>());
    assert(!document.Find("missing"));
    assert(document.Value("missing", 42) == 42);
    const auto nested = document.At("unknown").At("nested").Elements();
    assert(nested.size() == 3 && nested[0].IsNull());
    assert(nested[1].Get<int>() == 1 && nested[2].Get<std::string>() == "two");
    assert(Json::Parse(document.Encode()) == document);
    auto defaults = Json{{"enabled", true}, {"count", 10}};
    defaults.Merge(document);
    assert(defaults.At("count").Get<int>() == 10);
    assert(defaults.At("unknown") == document.At("unknown"));
    auto array = Json::Array();
    array.Append(document);
    assert(array.Elements().front() == document);
    bool wrappedError = false;
    try {
        (void)Json::Parse("{");
    } catch (const Json::Error &) {
        wrappedError = true;
    }
    assert(wrappedError);
    const auto expectJsonError = [](auto operation) {
        bool caught = false;
        try {
            operation();
        } catch (const Json::Error &) {
            caught = true;
        }
        assert(caught);
    };
    expectJsonError([] { (void)Json(1).At("missing"); });
    expectJsonError([] { (void)Json("text").Get<bool>(); });
    expectJsonError([] { Json(1).Set("key", true); });
    expectJsonError([] { Json(1).Append(true); });
    expectJsonError([] { Json(1).Merge(Json{{"key", true}}); });
    expectJsonError([] { (void)Json(std::string(1, '\xff')).Encode(); });

    ExpectFailure([] { (void)Json(1.5).Get<int>(); });
    ExpectFailure([] { (void)Json(-1).Get<unsigned>(); });
    ExpectFailure([] { (void)Json::Parse("{}").At("missing"); });
    ExpectFailure([] { (void)Json::Parse("null").Elements(); });
    ExpectFailure([] { (void)Json::Parse("[]").Members(); });
    const auto typed = ConnectionStatus::FromJson(Json("connected"));
    assert(typed.ToJson().Get<std::string>() == "connected");

    ExpectRoundTrip<ConnectionStatus>("connected");
    // Presentation receives canonical tokens without depending on JSON values.
    for (const auto *token : {"AES-128-CBC", "AES-192-CBC", "AES-256-CBC",
                              "AES-128-GCM", "AES-192-GCM", "AES-256-GCM"}) {
        assert(OpenVpnCipher::FromJson(token).ToString() == token);
    }
    for (const auto *token : {"SHA1", "SHA224", "SHA256", "SHA384", "SHA512"}) {
        assert(OpenVpnDigest::FromJson(token).ToString() == token);
    }
    ExpectFailure([] { (void)OpenVpnCipher{}.ToString(); });
    ExpectFailure([] { (void)OpenVpnDigest{static_cast<OpenVpnDigest::eOpenVpnDigest>(-1)}.ToString(); });
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
        assert(value.payload && json(*value.payload) == payload);
    }
    std::puts("C++ generated discriminator and optional-field tests passed");
}
