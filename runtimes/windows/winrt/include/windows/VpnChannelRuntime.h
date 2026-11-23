// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <chrono>
#include "partout.h"
#include <partout/models/TunnelControllerOptions.h>
#include <memory>
#include <winrt/Windows.Networking.Vpn.h>

namespace Partout {
// One runtime per channel. Callbacks must be serialized by the consumer.
// Profile and cache_dir are copied; logger_ctx must outlive the runtime and
// remain valid while registered with Partout's process-wide logger.
class VpnChannelRuntime {
public:
    // Maximum wait for the started tunnel engine to report a connected state.
    static constexpr auto StartupTimeout = std::chrono::seconds(30);
    // Maximum time allowed for the user to complete an interactive credential prompt.
    static constexpr auto CredentialPromptTimeout = std::chrono::seconds(60);
    // Delay between checks for credential completion, cancellation, or timeout.
    static constexpr auto AsyncPollInterval = std::chrono::milliseconds(20);

    // Runtime preferences shared with the Apple and Android controllers.
    VpnChannelRuntime(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        const char *profile,
        const partout_init_args &init_args,
        const partout_daemon_options &options,
        Models::TunnelControllerOptions controller_options = {}
    );
    VpnChannelRuntime(const VpnChannelRuntime &) = delete;
    VpnChannelRuntime &operator=(const VpnChannelRuntime &) = delete;
    ~VpnChannelRuntime();

    void Connect(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    void Disconnect(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    // Wakes startup; may run concurrently with Connect. Teardown stays serialized.
    void Cancel() noexcept;
    void GetKeepAlivePayload(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        winrt::Windows::Networking::Vpn::VpnPacketBuffer &keep_alive_packet
    );
    void Encapsulate(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &encapsulated_packets
    );
    void Decapsulate(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &decapsulated_packets,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &control_packets
    );

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace Partout
