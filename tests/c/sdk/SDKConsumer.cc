// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <partout.h>
#ifdef _WIN32
#include <partout_winrt.h>
#else
#include <partout_posix.h>
#endif

int main() {
    const char *version = partout_version();
    if (!version || !version[0]) return 1;
#ifdef _WIN32
    try {
        // Validate runtime linkage without creating an OS VPN connection.
        Partout::VpnChannelRuntime runtime(nullptr, "{}", {}, {});
        return 2;
    } catch (const winrt::hresult_invalid_argument &) {
        return 0;
    }
#else
    const auto functions = partout_posix_controller_functions();
    return functions.set_tunnel ? 0 : 2;
#endif
}
