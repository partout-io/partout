// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include <partout/extensions/ProfileExtensions.h>
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
    bool expects_otp = false;
    const auto prompt = [&](bool needs_otp) {
        ++prompts;
        assert(needs_otp == expects_otp);
        TunnelCredentials entered{};
        entered.username = "entered-user";
        entered.password = needs_otp ? "123456" : "entered-password";
        return entered;
    };
    const auto original = profile.ToJson();
    auto prepared = Profile::PrepareInteractive(profile, prompt);
    assert(prompts == 1);
    assert(profile.ToJson() == original);
    auto &module = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value;
    assert(module.credentials->username == "entered-user");
    assert(module.credentials->password == "entered-password");
    assert(prepared.userInfo == profile.userInfo);
    assert(prepared.modules.back() == profile.modules.back());
    // Saved complete credentials do not request input.
    profile = prepared;
    Profile::PrepareInteractive(profile, prompt);
    assert(prompts == 1);
    auto &saved = std::get<Models::TaggedModuleOpenVpn>(profile.modules.front()).value;
    saved.requiresInteractiveCredentials = true;
    Profile::PrepareInteractive(profile, prompt);
    assert(prompts == 2);
    saved.requiresInteractiveCredentials = false;
    saved.configuration->staticChallenge = true;
    Profile::PrepareInteractive(profile, prompt);
    assert(prompts == 3);

    expects_otp = true;
    saved.credentials->otpMethod.value = Method::append;
    saved.credentials->otp = "stale-code";
    prepared = Profile::PrepareInteractive(profile, prompt);
    const auto appended = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials;
    assert(appended->password == "entered-password");
    assert(appended->otpMethod.value == Method::append && appended->otp == "123456");
    assert(saved.credentials->password == "entered-password");
    assert(saved.credentials->otp == "stale-code");
    saved.credentials->otpMethod.value = Method::encode;
    saved.credentials->password = "p\xc3\xa4ss";
    prepared = Profile::PrepareInteractive(profile, prompt);
    assert(std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials->password ==
           "p\xc3\xa4ss");
    const auto encoded = std::get<Models::TaggedModuleOpenVpn>(prepared.modules.front()).value.credentials;
    assert(encoded->otpMethod.value == Method::encode && encoded->otp == "123456");

    // Prepare all active interactive modules, leaving inactive modules untouched.
    auto multiple = profile;
    auto second = std::get<Models::TaggedModuleOpenVpn>(profile.modules.front());
    second.value.id = "second";
    multiple.modules.push_back(second);
    multiple.activeModulesIds.push_back(second.value.id);
    second.value.id = "inactive";
    multiple.modules.push_back(second);
    const auto before_multiple = multiple.ToJson();
    const auto before_prompts = prompts;
    const auto all_prepared = Profile::PrepareInteractive(multiple, prompt);
    assert(prompts == before_prompts + 2);
    assert(multiple.ToJson() == before_multiple);
    assert(std::get<Models::TaggedModuleOpenVpn>(all_prepared.modules[0]).value.credentials->otp == "123456");
    assert(std::get<Models::TaggedModuleOpenVpn>(all_prepared.modules[2]).value.credentials->otp == "123456");
    assert(all_prepared.modules[3] == multiple.modules[3]);
    assert(Module::PrepareInteractive(profile.modules[1], prompt) == profile.modules[1]);
    assert(prompts == before_prompts + 2);

    const auto before_cancellation = profile.ToJson();
    bool canceled = false;
    try {
        Profile::PrepareInteractive(profile, [](bool) -> TunnelCredentials {
            throw std::runtime_error("Prompt canceled");
        }
        );
    } catch (const std::runtime_error &) {
        canceled = true;
    }
    assert(canceled && profile.ToJson() == before_cancellation);
    bool rejected = false;
    try {
        Profile::PrepareInteractive(profile, [](bool) {
            TunnelCredentials blank{};
            blank.username = "user";
            blank.password = " \t";
            return blank;
        }
        );
    } catch (const std::invalid_argument &) {
        rejected = true;
    }
    assert(rejected && profile.ToJson() == before_cancellation);
    profile.activeModulesIds.clear();
    const auto before_inactive = prompts;
    assert(Profile::PrepareInteractive(profile, prompt).ToJson() == profile.ToJson());
    assert(prompts == before_inactive);
}
