// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <partout/tunnel/Tunnel.h>
#include <partout/Runtime.h>
#include <partout/winrt/WinRTTunnelStrategy.h>
#include <partout/winrt/VpnChannelRuntime.h>
#include <memory>

int main() {
    if (Partout::Runtime::Version().empty()) return 1;
    // Construction and cancellation do not alter VPN registrations.
    Partout::Tunnel tunnel(std::make_unique<Partout::WinRTTunnelStrategy>("https://localhost"));
    tunnel.Cancel();
    try {
        // Resolves runtime methods against the combined shared library.
        // Rejects an absent channel before touching OS VPN configuration.
        Partout::Runtime::InitializationOptions initialization{};
        initialization.log_level = Partout::Runtime::LogLevel::Info;
        Partout::Runtime::DaemonOptions options{};
        options.cache_dir = std::string("temporary-cache");
        options.starts_immediately = true;
        options.crypto = Partout::Runtime::CryptoBackend::MbedTLS;
        Partout::VpnChannelRuntime runtime(nullptr, std::string("{}"), initialization, options);
        return 2;
    } catch (const winrt::hresult_invalid_argument &) {
        return 0;
    }
}
