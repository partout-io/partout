// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <functional>
#include <partout/models/TaggedProfile.h>

namespace Partout {
// The native prompt returns a username and either a password or an OTP in
// password. The returned profile is connection-local and must never be saved.
using CredentialPrompt = std::function<Models::OpenVpnCredentials(bool needsOTP)>;
Models::TaggedProfile PrepareInteractiveProfile(
    const Models::TaggedProfile &profile, const CredentialPrompt &prompt);
}
