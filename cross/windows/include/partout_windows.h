// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "partout.h"

#if defined(_WIN32) && defined(__cplusplus)
#include <memory>
#include <map>
#include <string>
#include <vector>
#include <winrt/Windows.Networking.Vpn.h>

namespace Partout {
namespace Models {
struct TaggedProfile;
struct TunnelSnapshot;
}

// Synchronous management API: call from a serialized background worker.
// Fetch is read-only. All methods require the consumer package identity.
// Include partout/models/TaggedProfile.h and TunnelSnapshot.h for typed values.
class Tunnel {
public:
    // Absolute placeholder URI supplied by the consumer app.
    // Actual VPN endpoints come from the saved profile configuration.
    explicit Tunnel(const std::string &serverUri);
    // When supplied, errors receives unavailable profiles by ID; snapshots
    // contain only observed states. Without it, any observation error throws.
    std::vector<Models::TunnelSnapshot> Fetch(std::map<std::string, std::string> *errors = nullptr);
    void Save(const Models::TaggedProfile &profile);
    void Connect(const std::string &id);
    void Disconnect(const std::string &id);
    void Remove(const std::string &id);
private:
    std::string serverUri_;
};

// One runtime per channel. Callbacks must be serialized by the consumer.
// Profile and cache_dir are copied; logger_ctx must outlive the runtime and
// remain valid while registered with Partout's process-wide logger.
class VpnChannelRuntime {
public:
    VpnChannelRuntime(winrt::Windows::Networking::Vpn::VpnChannel const &channel,
                      const char *profile, const partout_init_args &init_args,
                      const partout_daemon_options &options);
    ~VpnChannelRuntime();
    VpnChannelRuntime(const VpnChannelRuntime &) = delete;
    VpnChannelRuntime &operator=(const VpnChannelRuntime &) = delete;

    void Connect(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    void Disconnect(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    void GetKeepAlivePayload(winrt::Windows::Networking::Vpn::VpnChannel const &channel,
                             winrt::Windows::Networking::Vpn::VpnPacketBuffer &keep_alive_packet);
    void
    Encapsulate(winrt::Windows::Networking::Vpn::VpnChannel const &channel,
                winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets,
                winrt::Windows::Networking::Vpn::VpnPacketBufferList const &encapsulated_packets);
    void
    Decapsulate(winrt::Windows::Networking::Vpn::VpnChannel const &channel,
                winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet,
                winrt::Windows::Networking::Vpn::VpnPacketBufferList const &decapsulated_packets,
                winrt::Windows::Networking::Vpn::VpnPacketBufferList const &control_packets);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace Partout

#endif
