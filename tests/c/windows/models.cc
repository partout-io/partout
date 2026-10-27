// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "../../../cross/windows/src/models/ABIEnvelope.h"
#include "../../../cross/windows/src/models/ConnectionStatus.h"
#include "../../../cross/windows/src/models/CryptoBackend.h"
#include "../../../cross/windows/src/models/OnDemandModule.h"
#include "../../../cross/windows/src/models/TaggedModule_IP.h"
#include "../../../cross/windows/src/models/TaggedProfile.h"
#include <cassert>
#include <cstdio>

using namespace Partout::Models;
using nlohmann::json;

template<typename T>
void ExpectRoundTrip(const json &source) {
    const auto value = source.get<T>();
    value.Validate();
    assert(json(value) == source);
    assert(value.ToJson() == source);
    assert(T::FromJson(source) == value);
}

template<typename T>
void ExpectDecodeFailure(const json &source) {
    bool failed = false;
    try {
        (void)source.get<T>();
    } catch (const std::exception &) {
        failed = true;
    }
    assert(failed);
}

int main() {
    ExpectRoundTrip<ConnectionStatus>("connected");
    ExpectRoundTrip<CryptoBackend>(4);
    ExpectDecodeFailure<ConnectionStatus>("unknown");
    ExpectDecodeFailure<CryptoBackend>(99);
    ExpectDecodeFailure<IPModule>(json::object());

    const auto ip = json::parse(R"({"id":"ip","mtu":1400,"ipv4":{
        "subnets":["10.8.0.2/24"],"includedRoutes":[{}],"excludedRoutes":[]}})");
    ExpectRoundTrip<IPModule>(ip);
    const auto module = ip.get<IPModule>();
    assert(module.mtu == 1400);
    assert(!module.ipv6);

    const json tagged = {{"type", "IP"}, {"value", ip}};
    ExpectRoundTrip<TaggedModule_IP>(tagged);
    const json profile = {
        {"id", "profile"}, {"name", "Test"}, {"activeModulesIds", {"ip"}},
        {"modules", {tagged, {{"type", "FutureModule"}, {"value", {1, true, "test"}}}}},
        {"userInfo", {{"custom", json::array({nullptr, 42, false})}}}
    };
    ExpectRoundTrip<TaggedProfile>(profile);
    assert(profile.get<TaggedProfile>().modules.front().value == tagged);

    ExpectRoundTrip<OnDemandModule>(json::parse(R"({"id":"on-demand",
        "policy":"any","withSSIDs":{"home":true,"office":false},
        "withOtherNetworks":["mobile","ethernet"]})"));

    // JSONValue must preserve objects, arrays, scalars and null alike.
    for (const auto &payload : json::array({json::object(), json::array({1, 2}), "text", 7, true, nullptr})) {
        const json envelope = {{"payload", payload}};
        const auto value = envelope.get<ABIEnvelope>();
        assert(value.payload);
        assert(*value.payload == payload);
        assert(json(value) == envelope);
    }
    std::puts("C++ OpenAPI models passed");
}
