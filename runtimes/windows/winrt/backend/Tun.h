// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <partout/winrt/export.h>

#include <partout/IOTypes.h>
#include "Socket.h"
#include <winrt/Windows.Networking.Vpn.h>
#include <atomic>
#include <mutex>

namespace Partout {
// Lifecycle and writes run on the native command worker. StopWrites is atomic.
// Receive callbacks only enqueue borrowed input and must not reenter TUN APIs.
class Tun {
    // Owned by the controller; TUN handles and the socket writer borrow it.
    class State {
    public:
        winrt::Windows::Networking::Vpn::VpnChannel channel;
        // Held throughout native delivery and callback removal. The current Tun is
        // borrowed under this gate; its destructor unpublishes it before returning.
        std::mutex receive_mutex;
        Tun *tun = nullptr;
        Socket::Receiver link_receive;

        struct Counters {
            // Native receives hold receive_mutex. Writes run on the looper.
            // Snapshot all counters on the looper with receive_mutex held.
            uint64_t tun_read = 0, tun_dropped = 0, link_send = 0, link_send_failed = 0;
            uint64_t link_read = 0, tun_write = 0, tun_write_failed = 0;
        } counters;

        explicit State(winrt::Windows::Networking::Vpn::VpnChannel const &value) : channel(value) {}

        int32_t Write(const uint8_t *bytes, size_t length, bool send);
    };
    friend class TunnelController;

public:
    explicit Tun(State &state);
    PARTOUT_WINRT_API ~Tun() noexcept;
    Tun(const Tun &) = delete;
    Tun &operator=(const Tun &) = delete;

    // Removing the callback waits for in-flight delivery under the receive mutex.
    bool SetOnReceive(TunOnReceive callback);
    void ReportError(int32_t error);

    int32_t WriteStatus() const {
        return write_status_.load();
    }

    int32_t Write(const uint8_t *bytes, size_t length);
    void StopWrites();

private:
    State &state_; // Borrowed; the controller outlives every TUN handle.
    TunOnReceive callback_ = nullptr;
    std::atomic<int32_t> write_status_{0};
};
} // namespace Partout
