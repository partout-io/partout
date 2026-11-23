// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <functional>
#include <partout/Export.h>
#include <partout/tunnel/TunnelCredentials.h>
#include <partout/models/TaggedProfile.h>

namespace Partout::OpenVPN {
// The supplied prompt returns a username and either a password or an OTP in
// password. Preserve the OTP method for encoding by the OpenVPN session.
// The returned profile is connection-local and must never be saved.
using CredentialPrompt = std::function<TunnelCredentials(bool needs_otp)>;
PARTOUT_MODELS_API Models::TaggedProfile PrepareInteractiveProfile(
    const Models::TaggedProfile &profile, const CredentialPrompt &prompt
);
}
