// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <functional>
#include <partout/Export.h>
#include <partout/tunnel/TunnelCredentials.h>
#include <partout/models/TaggedModule.h>

namespace Partout {
// Returns a username and either a password or, when requested, an OTP in password.
using CredentialPrompt = std::function<TunnelCredentials(bool needs_otp)>;
}

namespace Partout::Module {
// Prepare connection-local credentials when required; preserve other modules.
// The returned module must never be saved.
PARTOUT_RUNTIME_API Models::TaggedModule PrepareInteractive(
    const Models::TaggedModule &module, const CredentialPrompt &prompt
);
}
