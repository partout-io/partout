// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include "InteractiveCredentials.h"
#include <algorithm>
#include <stdexcept>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>

namespace Partout {
namespace {
bool IsBlank(const std::string &value) {
    return value.find_first_not_of(" \t\r\n") == std::string::npos;
}

std::string Base64(const std::string &value) {
    using winrt::Windows::Security::Cryptography::CryptographicBuffer;
    const auto bytes = winrt::array_view<const uint8_t>(
        reinterpret_cast<const uint8_t *>(value.data()),
        reinterpret_cast<const uint8_t *>(value.data() + value.size()));
    return winrt::to_string(CryptographicBuffer::EncodeToBase64String(
        CryptographicBuffer::CreateFromByteArray(bytes)));
}
}

Models::TaggedProfile PrepareInteractiveProfile(
    const Models::TaggedProfile &profile, const CredentialPrompt &prompt) {
    using Method = Models::OpenVpnCredentialsOTPMethod;
    auto prepared = profile;
    for (auto &tagged : prepared.modules) {
        const auto openvpn = std::get_if<Models::TaggedModuleOpenVpn>(&tagged);
        if (!openvpn) continue;
        auto &module = openvpn->value;
        if (std::find(profile.activeModulesIds.begin(), profile.activeModulesIds.end(),
                      module.id) == profile.activeModulesIds.end()) continue;
        const auto &configuration = module.configuration;
        const auto &saved = module.credentials;
        const bool missing = !saved || (saved->username.empty() && saved->password.empty());
        const bool interactive = module.requiresInteractiveCredentials.value_or(false) ||
            (configuration && (configuration->staticChallenge.value_or(false) ||
                (configuration->authUserPass.value_or(false) && missing)));
        if (!interactive) continue;

        const auto method = saved ? saved->otpMethod.value : Method::none;
        const bool needsOTP = method != Method::none;
        auto entered = prompt(needsOTP);
        if (IsBlank(entered.username) || (needsOTP && IsBlank(entered.password))) {
            throw std::invalid_argument("Incomplete interactive credentials");
        }
        if (needsOTP) {
            const auto password = saved ? saved->password : std::string{};
            switch (method) {
            case Method::append:
                entered.password = password + entered.password;
                break;
            case Method::encode:
                entered.password = "SCRV1:" + Base64(password) + ":" + Base64(entered.password);
                break;
            default:
                throw std::invalid_argument("Unsupported OTP method");
            }
        }
        entered.otpMethod.value = Method::none;
        entered.otp.reset();
        module.credentials = std::move(entered);
        return prepared;
    }
    return prepared;
}
}
