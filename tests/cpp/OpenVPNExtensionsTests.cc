// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include <partout/extensions/OpenVPNExtensions.h>
#include <cassert>
#include <stdexcept>

using namespace Partout;
using Method = Models::OpenVpnCredentialsOTPMethod;

int main() {
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
        TunnelCredentials entered{};
        entered.username = "entered-user";
        entered.password = needsOTP ? "123456" : "entered-password";
        return entered;
    };
    const auto original = profile.ToJson();
    auto prepared = OpenVPN::PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 1);
    assert(profile.ToJson() == original);
    auto &module = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value;
    assert(module.credentials->username == "entered-user");
    assert(module.credentials->password == "entered-password");
    assert(prepared.userInfo == profile.userInfo);
    assert(prepared.modules.back() == profile.modules.back());
    // Saved complete credentials do not request input.
    profile = prepared;
    OpenVPN::PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 1);
    auto &saved = std::get<Models::TaggedModuleOpenVpn>(profile.modules.front()).value;
    saved.requiresInteractiveCredentials = true;
    OpenVPN::PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 2);
    saved.requiresInteractiveCredentials = false;
    saved.configuration->staticChallenge = true;
    OpenVPN::PrepareInteractiveProfile(profile, prompt);
    assert(prompts == 3);

    expectsOTP = true;
    saved.credentials->otpMethod.value = Method::append;
    saved.credentials->otp = "stale-code";
    prepared = OpenVPN::PrepareInteractiveProfile(profile, prompt);
    const auto appended = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials;
    assert(appended->password == "entered-password");
    assert(appended->otpMethod.value == Method::append && appended->otp == "123456");
    assert(saved.credentials->password == "entered-password");
    assert(saved.credentials->otp == "stale-code");
    saved.credentials->otpMethod.value = Method::encode;
    saved.credentials->password = "p\xc3\xa4ss";
    prepared = OpenVPN::PrepareInteractiveProfile(profile, prompt);
    assert(std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials->password ==
           "p\xc3\xa4ss");
    const auto encoded = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials;
    assert(encoded->otpMethod.value == Method::encode && encoded->otp == "123456");

    const auto beforeCancellation = profile.ToJson();
    bool canceled = false;
    try {
        OpenVPN::PrepareInteractiveProfile(profile, [](bool) -> TunnelCredentials {
            throw std::runtime_error("Prompt canceled");
        }
        );
    } catch (const std::runtime_error &) {
        canceled = true;
    }
    assert(canceled && profile.ToJson() == beforeCancellation);
    bool rejected = false;
    try {
        OpenVPN::PrepareInteractiveProfile(profile, [](bool) {
            TunnelCredentials blank{};
            blank.username = "user";
            blank.password = " \t";
            return blank;
        }
        );
    } catch (const std::invalid_argument &) {
        rejected = true;
    }
    assert(rejected && profile.ToJson() == beforeCancellation);
    profile.activeModulesIds.clear();
    const auto beforeInactive = prompts;
    assert(OpenVPN::PrepareInteractiveProfile(profile, prompt).ToJson() == profile.ToJson());
    assert(prompts == beforeInactive);
}
