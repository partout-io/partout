// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "tun_settings.h"
#include <windows.h>
#include "tun.h"
#include "loop.h"
#include "socket.h"
#include "windows/log.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Storage.Streams.h>
#include <chrono>
#include <mutex>
#include <utility>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Vpn;

namespace Partout {

TunnelController::TunnelController(RuntimeLoop &loop, VpnChannel const &channel)
    : loop_(loop), state_(std::make_unique<Tun::State>(channel)) {}

TunnelController::~TunnelController() {
    monitor_.Stop();
    // Destruction must complete close, rather than queue a borrowed this pointer.
    loop_.Perform([this] {
        Close();
    });
}

bool TunnelController::Associate(Socket &socket) noexcept {
    try {
        const auto &channel = state_->channel;
        const auto transport = socket.Transport();
        if (!channel || !transport) return false;
        if (socket.IsUnconnected()) {
            AssociateUnconnected(socket);
        } else if (transport_ != transport) {
            channel.AssociateTransport(transport, nullptr);
            transport_ = transport;
            socket_ = &socket;
        }
    } catch (...) {
        windows_log(WindowsLogError, "Partout::TunnelController: associate failed: HRESULT=0x%08x",
                  static_cast<unsigned int>(to_hresult().value));
        return false;
    }
    return true;
}

void TunnelController::AssociateUnconnected(Socket &socket) {
    // UDP sockets with multiple destinations keep their binds independent of the channel.
    // Link refresh may preserve the channel while replacing its independent socket.
    const auto profile = PhysicalProfile();
    if (!profile) throw hresult_error(E_FAIL, L"No physical network profile");
    udp_adapter_ = profile.NetworkAdapter();
    socket.SetAdapter(udp_adapter_);
    if (idle_transport_) return;
    if (transport_) throw hresult_illegal_method_call();
    Sockets::DatagramSocket idle;
    try {
        state_->channel.AssociateTransport(idle, nullptr);
        // UDP connect sends no application payload. This socket exists
        // only to satisfy the framework; application destinations use independent UDP sockets.
        // TEST-NET-1 avoids DNS and any dependency on a real server.
        const auto connect = idle.ConnectAsync(HostName{L"192.0.2.1"}, L"9");
        if (connect.wait_for(std::chrono::seconds(5)) == AsyncStatus::Started) {
            connect.Cancel();
            throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT));
        }
        connect.GetResults();
    } catch (...) {
        idle.Close();
        throw;
    }
    idle_transport_ = idle;
    transport_ = idle;
    windows_log(WindowsLogDebug, "Partout::TunnelController: idle UDP transport ready");
}

std::unique_ptr<Tun> TunnelController::Open(const char *info_json) {
    if (!state_->channel || !transport_) return nullptr;
    auto tun = std::make_unique<Tun>(*state_);
    if (!started_) {
        const TunSettings settings{info_json};
        if (!idle_transport_) {
            auto receive =
                socket_->TakeOver([state = state_.get()](const uint8_t *bytes, size_t length) {
                    return state->Send(bytes, length);
                });
            std::lock_guard lock(state_->receive_mutex);
            state_->link_receive = std::move(receive);
        }
        // Windows requires null for an absent address family, not an empty view.
        state_->channel.StartWithMainTransport(
            settings.IPv4().Size() ? settings.IPv4().GetView() : nullptr,
            settings.IPv6().Size() ? settings.IPv6().GetView() : nullptr, VpnInterfaceId{nullptr},
            settings.Routes(), settings.Domains(), settings.MTU(), settings.MaxFrame(), false,
            transport_);
        {
            std::lock_guard lock(state_->write_mutex);
            state_->accepting_writes = true;
        }
        started_ = true;
        socket_ = nullptr; // TakeOver's receiver retains the socket state.
        windows_log(WindowsLogInfo,
                  "Partout::TunnelController: channel opened: ipv4=%u, ipv6=%u, mtu=%u",
                  settings.IPv4().Size(), settings.IPv6().Size(), settings.MTU());
    }
    std::lock_guard lock(state_->receive_mutex);
    state_->tun = tun.get();
    return tun;
}

void TunnelController::Close() noexcept {
    if (!loop_.IsWorker()) {
        try {
            // The runtime retains this controller until queued close completes.
            loop_.Schedule([this] {
                Close();
            });
        } catch (...) {}
        return;
    }
    {
        std::lock_guard lock(state_->receive_mutex);
        if (auto tun = std::exchange(state_->tun, nullptr)) {
            tun->StopWrites();
            tun->callback_ = nullptr;
            tun->batch_callback_ = nullptr;
        }
        state_->link_receive = nullptr;
    }
    {
        std::lock_guard lock(state_->write_mutex);
        state_->accepting_writes = false;
    }
    if (started_) {
        try {
            state_->channel.Stop();
            started_ = false;
        } catch (...) {
            windows_log(WindowsLogError, "Partout::TunnelController: close failed: HRESULT=0x%08x",
                      static_cast<unsigned int>(to_hresult().value));
        }
        Tun::State::Counters counters;
        {
            std::lock_guard lock(state_->receive_mutex);
            std::lock_guard write_lock(state_->write_mutex);
            counters = state_->counters;
        }
        windows_log(WindowsLogInfo,
                  "Partout::TunnelController: packet totals: tun_read=%llu, tun_dropped=%llu, "
                  "link_send=%llu, link_send_failed=%llu, link_read=%llu, tun_write=%llu, "
                  "tun_write_failed=%llu",
                  counters.tun_read, counters.tun_dropped, counters.link_send,
                  counters.link_send_failed, counters.link_read, counters.tun_write,
                  counters.tun_write_failed);
    }
    // Release setup resources even if channel startup failed.
    try {
        if (idle_transport_) idle_transport_.Close();
    } catch (...) {}
    idle_transport_ = nullptr;
    transport_ = nullptr;
    udp_adapter_ = nullptr;
    socket_ = nullptr;
}

void TunnelController::Encapsulate(VpnPacketBufferList const &packets) {
    const auto count = packets.Size();
    std::lock_guard lock(state_->receive_mutex);
    ScopedIOTiming timing(state_->receive_time[0]);
    auto &counters = state_->counters;
    counters.tun_read += count;
    const auto tun = state_->tun;
    if (!tun || (!tun->callback_ && !tun->batch_callback_)) {
        counters.tun_dropped += count;
        return;
    }
    if (tun->batch_callback_) {
        PacketView views[MaxPacketBatch];
        size_t used = 0;
        for (uint32_t i = 0; i < count; ++i) {
            const auto packet = packets.RemoveAtBegin();
            packets.Append(packet); // Keep native ownership until callback return.
            const auto buffer = packet.Buffer();
            views[used++] = {buffer.data(), buffer.Length()};
            if (used == MaxPacketBatch || i + 1 == count) {
                if (!tun->batch_callback_(views, used, 0)) counters.tun_dropped += used;
                used = 0;
            }
        }
        return;
    }
    // VpnPacketBufferList's iterable view may be empty despite a nonzero Size.
    // Rotate through the native list, restoring ownership before invoking user code.
    // Windows reclaims these input buffers when the plugin callback returns.
    for (uint32_t i = 0; i < count; ++i) {
        const auto packet = packets.RemoveAtBegin();
        packets.Append(packet);
        const auto buffer = packet.Buffer();
        if (!tun->callback_(buffer.data(), buffer.Length(), 0)) ++counters.tun_dropped;
    }
}

void TunnelController::Decapsulate(VpnPacketBuffer const &packet) {
    std::lock_guard lock(state_->receive_mutex);
    ScopedIOTiming timing(state_->receive_time[1]);
    ++state_->counters.link_read;
    if (!state_->link_receive) return;
    const auto buffer = packet.Buffer();
    state_->link_receive(buffer.data(), buffer.Length());
}

} // namespace Partout
