// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "partout_winrt.h"
#include <cstring>

int main() {
    if (!partout_version() || std::strlen(partout_version()) == 0) return 1;
    try {
        // Resolves runtime methods against the separate core/backend libraries.
        // Rejects an absent channel before touching OS VPN configuration.
        Partout::VpnChannelRuntime runtime(nullptr, "{}", {}, {});
        return 2;
    } catch (const winrt::hresult_invalid_argument &) {
        return 0;
    }
}
