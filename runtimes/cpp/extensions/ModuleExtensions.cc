// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include <partout/extensions/ModuleExtensions.h>
#include <stdexcept>

namespace {
bool IsBlank(const std::string &value) {
    return value.find_first_not_of(" \t\r\n") == std::string::npos;
}
}

using namespace Partout;

Models::TaggedModule Partout::Module::PrepareInteractive(
    const Models::TaggedModule &tagged, const CredentialPrompt &prompt
) {
    using Method = Models::OpenVpnCredentialsOTPMethod;
    auto prepared = tagged;
    const auto openvpn = std::get_if<Models::TaggedModuleOpenVpn>(&prepared);
    if (!openvpn) return prepared;
    auto &module = openvpn->value;
    const auto &configuration = module.configuration;
    const auto &saved = module.credentials;
    const bool missing = !saved || (saved->username.empty() && saved->password.empty());
    const bool interactive = module.requiresInteractiveCredentials.value_or(false) ||
        (configuration && (configuration->staticChallenge.value_or(false) ||
            (configuration->authUserPass.value_or(false) && missing)));
    if (!interactive) return prepared;

    const auto method = saved ? saved->otpMethod.value : Method::none;
    const bool needs_otp = method != Method::none;
    const auto response = prompt(needs_otp);
    Models::OpenVpnCredentials entered{};
    entered.username = response.username;
    entered.password = response.password;
    if (IsBlank(entered.username) || (needs_otp && IsBlank(entered.password))) {
        throw std::invalid_argument("Incomplete interactive credentials");
    }
    entered.otpMethod.value = method;
    if (needs_otp) {
        if (method != Method::append && method != Method::encode)
            throw std::invalid_argument("Unsupported OTP method");
        // The OpenVPN session applies append/SCRV1 encoding once, at authentication.
        entered.otp = std::move(entered.password);
        entered.password = saved->password;
    }
    module.credentials = std::move(entered);
    return prepared;
}
