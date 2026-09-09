// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "partout.h"

#if defined(_WIN32) && defined(__cplusplus)
#include <memory>
#include <winrt/Windows.Networking.Vpn.h>

using namespace winrt::Windows::Networking::Vpn;

#if defined(PARTOUT_WINRT_EXPORTS)
#define PARTOUT_WINRT_API __declspec(dllexport)
#else
#define PARTOUT_WINRT_API __declspec(dllimport)
#endif

// One runtime per channel. Callbacks must be serialized by the consumer.
// Profile and cache_dir are copied; logger_ctx must outlive the runtime and
// remain valid while registered with Partout's process-wide logger.
class PartoutVpnChannelRuntime {
public:
    PARTOUT_WINRT_API PartoutVpnChannelRuntime(
        VpnChannel const &channel,
        const char *profile,
        const partout_init_args &init_args,
        const partout_daemon_options &options);
    PARTOUT_WINRT_API ~PartoutVpnChannelRuntime();
    PartoutVpnChannelRuntime(const PartoutVpnChannelRuntime &) = delete;
    PartoutVpnChannelRuntime &operator=(const PartoutVpnChannelRuntime &) = delete;

    PARTOUT_WINRT_API void Connect(VpnChannel const &channel);
    PARTOUT_WINRT_API void Disconnect(VpnChannel const &channel);
    PARTOUT_WINRT_API void GetKeepAlivePayload(
        VpnChannel const &channel,
        VpnPacketBuffer &keep_alive_packet);
    PARTOUT_WINRT_API void Encapsulate(
        VpnChannel const &channel,
        VpnPacketBufferList const &packets,
        VpnPacketBufferList const &encapsulated_packets);
    PARTOUT_WINRT_API void Decapsulate(
        VpnChannel const &channel,
        VpnPacketBuffer const &packet,
        VpnPacketBufferList const &decapsulated_packets,
        VpnPacketBufferList const &control_packets);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
#undef PARTOUT_WINRT_API
#endif
