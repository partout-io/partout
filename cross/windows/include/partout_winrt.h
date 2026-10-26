// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "partout.h"

#if defined(_WIN32) && defined(__cplusplus)
#include <memory>
#include <winrt/Windows.Networking.Vpn.h>

#if defined(PARTOUT_WINRT_EXPORTS)
#define PARTOUT_WINRT_API __declspec(dllexport)
#else
#define PARTOUT_WINRT_API __declspec(dllimport)
#endif

namespace Partout {

// One runtime per channel. Callbacks must be serialized by the consumer.
// Profile and cache_dir are copied; logger_ctx must outlive the runtime and
// remain valid while registered with Partout's process-wide logger.
class VpnChannelRuntime {
public:
    PARTOUT_WINRT_API VpnChannelRuntime(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        const char *profile,
        const partout_init_args &init_args,
        const partout_daemon_options &options);
    PARTOUT_WINRT_API ~VpnChannelRuntime();
    VpnChannelRuntime(const VpnChannelRuntime &) = delete;
    VpnChannelRuntime &operator=(const VpnChannelRuntime &) = delete;

    PARTOUT_WINRT_API void Connect(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    PARTOUT_WINRT_API void Disconnect(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    PARTOUT_WINRT_API void GetKeepAlivePayload(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        winrt::Windows::Networking::Vpn::VpnPacketBuffer &keep_alive_packet);
    PARTOUT_WINRT_API void Encapsulate(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &encapsulated_packets);
    PARTOUT_WINRT_API void Decapsulate(
        winrt::Windows::Networking::Vpn::VpnChannel const &channel,
        winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &decapsulated_packets,
        winrt::Windows::Networking::Vpn::VpnPacketBufferList const &control_packets);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace Partout

#undef PARTOUT_WINRT_API
#endif
