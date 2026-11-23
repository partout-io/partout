// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include "InteractiveCredentials.h"
#include <cassert>
#include <stdexcept>
#include <winrt/base.h>

using namespace Partout;
using Method = Models::OpenVpnCredentialsOTPMethod;

int main() {
    winrt::init_apartment();
    auto profile = Models::TaggedProfile::FromJson(Partout::Json::Parse(R"({
        "id":"profile", "name":"Test", "userInfo":{"keep":"metadata"},
        "activeModulesIds":["vpn"], "modules":[
            {"type":"OpenVPN", "value":{"id":"vpn", "configuration":{"authUserPass":true}}},
            {"type":"Custom", "value":{"innerType":"Provider", "json":{"id":"hidden"}}}
        ]
    })"));
    unsigned prompts = 0;
    bool expectsOTP = false;
    const auto prompt = [&](bool needsOTP) {
        ++prompts;
        assert(needsOTP == expectsOTP);
        Models::OpenVpnCredentials entered{};
        entered.username = "entered-user";
        entered.password = needsOTP ? "123456" : "entered-password";
        entered.otpMethod.value = Method::none;
        return entered;
    };
    const auto original = profile.ToJson();
    auto prepared = PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 1);
    assert(profile.ToJson() == original);
    auto &module = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value;
    assert(module.credentials->username == "entered-user");
    assert(module.credentials->password == "entered-password");
    assert(prepared.userInfo == profile.userInfo);
    assert(prepared.modules.back() == profile.modules.back());
    // Saved complete credentials do not request input.
    profile = prepared;
    PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 1);
    auto &saved = std::get<Models::TaggedModuleOpenVpn>(profile.modules.front()).value;
    saved.requiresInteractiveCredentials = true;
    PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 2);
    saved.requiresInteractiveCredentials = false;
    saved.configuration->staticChallenge = true;
    PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 3);

    expectsOTP = true;
    saved.credentials->otpMethod.value = Method::append;
    saved.credentials->otp = "stale-code";
    prepared = PrepareInteractiveProfile(profile, prompt);
    const auto appended = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials;
    assert(appended->password == "entered-password123456");
    assert(appended->otpMethod.value == Method::none && !appended->otp);
    assert(saved.credentials->password == "entered-password");
    assert(saved.credentials->otp == "stale-code");
    saved.credentials->otpMethod.value = Method::encode;
    saved.credentials->password = "p\xc3\xa4ss";
    prepared = PrepareInteractiveProfile(profile, prompt);
    assert(std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials->password ==
           "SCRV1:cMOkc3M=:MTIzNDU2");

    const auto beforeCancellation = profile.ToJson();
    bool canceled = false;
    try {
        PrepareInteractiveProfile(profile, [](bool) -> Models::OpenVpnCredentials {
            throw winrt::hresult_canceled();
        });
    } catch (const winrt::hresult_canceled &) {
        canceled = true;
    }
    assert(canceled && profile.ToJson() == beforeCancellation);
    bool rejected = false;
    try {
        PrepareInteractiveProfile(profile, [](bool) {
            Models::OpenVpnCredentials blank{};
            blank.username = "user";
            blank.password = " \t";
            return blank;
        });
    } catch (const std::invalid_argument &) {
        rejected = true;
    }
    assert(rejected && profile.ToJson() == beforeCancellation);
    profile.activeModulesIds.clear();
    const auto beforeInactive = prompts;
    assert(PrepareInteractiveProfile(profile, prompt).ToJson() == profile.ToJson());
    assert(prompts == beforeInactive);
}
