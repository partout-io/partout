// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <partout/extensions/ModuleExtensions.h>
#include <partout/models/TaggedProfile.h>

namespace Partout::Profile {
// Prepare every active module. The connection-local result must never be saved.
PARTOUT_API Models::TaggedProfile PrepareInteractive(
    const Models::TaggedProfile &profile, const CredentialPrompt &prompt
);
}
