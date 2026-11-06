// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "windows/export.h"

#include "io_types.h"
#include "io_metrics.h"
#include "socket.h"
#include "network.h"
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.Vpn.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <memory>
#include <atomic>
#include <mutex>

namespace Partout {
class RuntimeLoop;

// Lifecycle runs on the native command worker. Producer writes are synchronous
// and serialized with channel close. StopWrites is atomic. Receive callbacks
// must not reenter callback management or lifecycle APIs.
class Tun {
    // Owned by the controller; TUN handles and the socket writer borrow it.
    class State {
    public:
        winrt::Windows::Networking::Vpn::VpnChannel channel;
        // Producers submit directly. Close waits for accepted submissions before
        // stopping the channel; no producer waits for the native command worker.
        std::mutex write_mutex;
        bool accepting_writes = false;
        // Held throughout native delivery and callback removal. The current Tun is
        // borrowed under this gate; its destructor unpublishes it before returning.
        // Channel submission from a receive callback may reenter native delivery.
        // The Zig execution gate queues that nested receive rather than recursing
        // into protocol state.
        std::recursive_mutex receive_mutex;
        Tun *tun = nullptr;
        Socket::Receiver link_receive;

        struct Counters {
            // Receives hold receive_mutex; writes hold write_mutex.
            // Snapshots acquire both gates, in that order.
            uint64_t tun_read = 0, tun_dropped = 0, link_send = 0, link_send_failed = 0;
            uint64_t link_read = 0, tun_write = 0, tun_write_failed = 0;
        } counters;

        // Index 0 is downstream into TUN; index 1 is upstream into the link.
        IOTiming get_buffer_time[2], copy_time[2], append_time[2], flush_time[2], receive_time[2];

        explicit State(winrt::Windows::Networking::Vpn::VpnChannel const &value) : channel(value) {}

        ~State() {
            for (size_t i = 0; i < 2; ++i) {
                get_buffer_time[i].Log(this, i ? "channel.link.get_buffer" : "channel.tun.get_buffer");
                copy_time[i].Log(this, i ? "channel.link.copy" : "channel.tun.copy");
                append_time[i].Log(this, i ? "channel.link.append" : "channel.tun.append");
                flush_time[i].Log(this, i ? "channel.link.flush" : "channel.tun.flush");
            }
            receive_time[0].Log(this, "channel.encapsulate_callback_excluding_lock_wait");
            receive_time[1].Log(this, "channel.decapsulate_callback_excluding_lock_wait");
        }

        int32_t Send(const uint8_t *bytes, size_t length) {
            const PacketView packet{bytes, length};
            size_t written = 0;
            return SendBatch(&packet, 1, &written);
        }
        int32_t SendBatch(const PacketView *packets, size_t count, size_t *written);
        int32_t ReceiveBatch(const PacketView *packets, size_t count, size_t *written);

    private:
        void AppendSend(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);
        void FlushSend();
        void AppendReceive(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);
        void FlushReceive();
    };
    friend class TunnelController;

public:
    explicit Tun(State &state);
    PARTOUT_WINDOWS_API ~Tun() noexcept;
    Tun(const Tun &) = delete;
    Tun &operator=(const Tun &) = delete;

    // Removing the callback waits for in-flight delivery under the receive mutex.
    bool SetOnReceive(TunOnReceive callback);
    bool SetOnReceiveBatch(TunOnReceiveBatch callback);
    void ReportError(int32_t error);

    int32_t WriteStatus() const {
        return write_status_.load();
    }

    int32_t Write(const uint8_t *bytes, size_t length);
    int32_t WriteBatch(const PacketView *packets, size_t count, size_t *written);
    void StopWrites();

private:
    State &state_; // Borrowed; the controller outlives every TUN handle.
    TunOnReceive callback_ = nullptr;
    TunOnReceiveBatch batch_callback_ = nullptr;
    std::atomic<int32_t> write_status_{0};
};

// Association, Open and Close run on the same native worker. Destruction follows
// daemon shutdown. Native receives share Tun's gate.
class TunnelController {
public:
    PARTOUT_WINDOWS_API TunnelController(RuntimeLoop &, winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    PARTOUT_WINDOWS_API ~TunnelController();
    TunnelController(const TunnelController &) = delete;
    TunnelController &operator=(const TunnelController &) = delete;

    bool Associate(Socket &socket) noexcept;

    RuntimeLoop &Loop() const {
        return loop_;
    }

    NetworkMonitor &Monitor() {
        return monitor_;
    }

    PARTOUT_WINDOWS_API std::unique_ptr<Tun> Open(const char *info_json);
    PARTOUT_WINDOWS_API void Close() noexcept;
    PARTOUT_WINDOWS_API void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    PARTOUT_WINDOWS_API void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

private:
    void AssociateUnconnected(Socket &socket);
    RuntimeLoop &loop_; // Runtime closes and destroys the controller before the loop.
    NetworkMonitor monitor_;

    // Handles and socket writers are drained before controller destruction.
    std::unique_ptr<Tun::State> state_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket idle_transport_{nullptr};
    winrt::Windows::Networking::Connectivity::NetworkAdapter udp_adapter_{nullptr};
    bool started_ = false;
    Socket *socket_ = nullptr; // Borrowed until Open takes over; the link owns it.
};

} // namespace Partout
