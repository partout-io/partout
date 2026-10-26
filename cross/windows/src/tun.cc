// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "tun_settings.h"
#include <windows.h>
#include "tun.h"
#include "socket.h"
#include "winrt/log.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Storage.Streams.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Vpn;

// Shared with retained TUN handles and the socket writer; no controller capture.
struct WinrtPacketCounters {
    std::atomic<uint64_t> tun_read{0}, tun_dropped{0}, link_send{0}, link_send_failed{0};
    std::atomic<uint64_t> link_read{0}, tun_write{0}, tun_write_failed{0};
};

struct WinrtTun {
    VpnChannel channel;
    std::shared_ptr<WinrtPacketCounters> counters;
    std::mutex receive_mutex;
    winrt_tun_on_receive callback = nullptr;
    void *context = nullptr;
    std::mutex write_mutex;
    std::atomic<bool> writes_stopped{false};

    explicit WinrtTun(VpnChannel const &value) : channel(value) {}
};

struct WinrtTunHandle { std::shared_ptr<WinrtTun> state; };

static int32_t write_channel(VpnChannel const &channel, const uint8_t *bytes, size_t length, bool send) {
    if (!bytes || !length || length > UINT32_MAX) return E_INVALIDARG;
    const auto append = [&](VpnPacketBuffer const &packet) {
        if (!send) {
            channel.AppendVpnReceivePacketBuffer(packet);
            return;
        }
        channel.AppendVpnSendPacketBuffer(packet);
    };
    const auto flush = [&] {
        if (!send) {
            channel.FlushVpnReceivePacketBuffers();
            return;
        }
        channel.FlushVpnSendPacketBuffers();
    };
    VpnPacketBuffer packet{nullptr};
    const char *stage = "get buffer";
    uint32_t capacity = 0;
    try {
        packet = send ? channel.GetVpnSendPacketBuffer() : channel.GetVpnReceivePacketBuffer();
        const auto buffer = packet.Buffer();
        capacity = buffer.Capacity();
        stage = "copy packet";
        if (length > capacity) throw hresult_invalid_argument();
        memcpy(buffer.data(), bytes, length);
        buffer.Length(static_cast<uint32_t>(length));
        stage = "append";
        append(packet);
        packet = nullptr; // Ownership returned to the channel.
        stage = "flush";
        flush();
        return 0;
    } catch (...) {
        const auto error = to_hresult().value;
        winrt_log(WinrtLogError, "WinRT %s write failed during %s: HRESULT 0x%08x, length=%zu, capacity=%u",
            send ? "link" : "TUN", stage, static_cast<unsigned int>(error), length, capacity);
        // Return an unused pool buffer even if preparing the packet failed.
        if (!packet) return error;
        try {
            packet.Buffer().Length(0);
            append(packet);
            flush();
        } catch (...) {}
        return error;
    }
}

namespace Partout {

TunnelController::TunnelController(VpnChannel const &channel)
    : channel_(channel), counters_(std::make_shared<WinrtPacketCounters>()) {}

TunnelController::~TunnelController() { Stop(); }

bool TunnelController::Associate(Socket *socket) noexcept {
    try {
        if (!socket) return false;
        const auto transport = socket->Transport();
        if (!channel_ || !transport) return false;
        if (!socket->IsUnconnected()) {
            if (transport_ == transport) return true;
            channel_.AssociateTransport(transport, nullptr);
            transport_ = transport;
            socket_ = socket;
            return true;
        }
        // The channel needs a transport, but it must not own WG's UDP bind.
        // Keep the adapter across WG bind replacement, including after Start.
        if (!udp_adapter_) {
            const auto profile = Connectivity::NetworkInformation::GetInternetConnectionProfile();
            if (!profile) throw hresult_error(E_FAIL, L"No physical network profile");
            udp_adapter_ = profile.NetworkAdapter();
        }
        socket->SetAdapter(udp_adapter_);
        if (idle_transport_) return true;
        if (transport_) throw hresult_illegal_method_call();
        Sockets::DatagramSocket idle;
        try {
            channel_.AssociateTransport(idle, nullptr);
            // UDP connect sends no application payload. This socket exists
            // only to satisfy the framework; no WG peer is mapped onto it.
            // TEST-NET-1 avoids DNS and any dependency on a real server.
            const auto connect = idle.ConnectAsync(HostName{L"192.0.2.1"}, L"9");
            if (connect.wait_for(std::chrono::seconds(5)) == AsyncStatus::Started) {
                connect.Cancel();
                throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT));
            }
            connect.GetResults();
        } catch (...) { idle.Close(); throw; }
        idle_transport_ = idle;
        transport_ = idle;
        winrt_log(WinrtLogNotice, "WinRT independent UDP: idle channel transport ready");
        return true;
    } catch (...) {
        winrt_log(WinrtLogError, "Partout::TunnelController.Associate failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return false;
    }
}

bool TunnelController::Start(const char *info_json) noexcept {
    try {
        if (!channel_ || !transport_) return false;
        if (started_) return true;
        const auto settings = partout::windows::TunnelSettings::parse(info_json, idle_transport_ ? 1420 : 1400);
        if (!idle_transport_) {
            auto receive = socket_->TakeOver([channel = channel_, counters = counters_](const uint8_t *bytes, size_t length) {
                const auto result = write_channel(channel, bytes, length, true);
                (result == 0 ? counters->link_send : counters->link_send_failed).fetch_add(1, std::memory_order_relaxed);
                return result;
            });
            std::lock_guard lock(input_mutex_);
            link_receive_ = std::move(receive);
        }
        // Windows requires null for an absent address family, not an empty view.
        channel_.StartWithMainTransport(
            settings.ipv4.Size() ? settings.ipv4.GetView() : nullptr,
            settings.ipv6.Size() ? settings.ipv6.GetView() : nullptr,
            VpnInterfaceId{nullptr}, settings.routes, settings.domains,
            settings.mtu, settings.maxFrame(), false, transport_);
        started_ = true;
        winrt_log(WinrtLogDebug, "Partout::TunnelController: Started (IPv4=%u, IPv6=%u, MTU=%u)",
            settings.ipv4.Size(), settings.ipv6.Size(), settings.mtu);
        return true;
    } catch (hresult_error const &error) {
        winrt_log(WinrtLogError, "Partout::TunnelController.Start failed: HRESULT 0x%08x (%ls)",
            static_cast<unsigned int>(error.code().value), error.message().c_str());
        return false;
    } catch (...) {
        winrt_log(WinrtLogError, "Partout::TunnelController.Start failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return false;
    }
}

void TunnelController::Stop() noexcept {
    std::shared_ptr<WinrtTun> tun;
    {
        std::lock_guard lock(input_mutex_);
        tun = std::exchange(tun_, nullptr);
    }
    if (tun) {
        tun->writes_stopped.store(true);
        std::lock_guard lock(tun->receive_mutex);
        tun->callback = nullptr;
        tun->context = nullptr;
    }
    // Close the idle transport even if channel startup failed.
    const auto close_idle = [&] {
        if (!idle_transport_) return;
        try { idle_transport_.Close(); } catch (...) {}
        idle_transport_ = nullptr;
        transport_ = nullptr;
        udp_adapter_ = nullptr;
    };
    if (!started_) {
        close_idle();
        return;
    }
    try {
        std::unique_lock<std::mutex> writes;
        if (tun) writes = std::unique_lock(tun->write_mutex);
        channel_.Stop();
        started_ = false;
    } catch (...) {
        winrt_log(WinrtLogError, "Partout::TunnelController.Stop failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
    }
    close_idle();
    winrt_log(WinrtLogNotice,
        "VPN packets (controller totals): TUN read=%llu, TUN dropped=%llu, link send=%llu, link send failed=%llu, link read=%llu, TUN write=%llu, TUN write failed=%llu",
        counters_->tun_read.load(), counters_->tun_dropped.load(), counters_->link_send.load(),
        counters_->link_send_failed.load(), counters_->link_read.load(), counters_->tun_write.load(), counters_->tun_write_failed.load());
}

winrt_tun TunnelController::Open(const char *info_json) {
    auto state = std::make_shared<WinrtTun>(channel_);
    state->counters = counters_;
    auto handle = std::make_unique<WinrtTunHandle>(WinrtTunHandle{state});
    if (!Start(info_json)) return nullptr;
    std::lock_guard lock(input_mutex_);
    tun_ = std::move(state);
    return handle.release();
}

void TunnelController::Encapsulate(VpnPacketBufferList const &packets) {
    // Leave input buffers in the platform list: Windows reclaims them on return.
    std::shared_ptr<WinrtTun> tun;
    { std::lock_guard lock(input_mutex_); tun = tun_; }
    counters_->tun_read.fetch_add(packets.Size(), std::memory_order_relaxed);
    if (!tun) {
        counters_->tun_dropped.fetch_add(packets.Size(), std::memory_order_relaxed);
        return;
    }
    std::lock_guard lock(tun->receive_mutex);
    // VpnPacketBufferList's iterable view may be empty despite a nonzero Size.
    // Rotate through the native list, restoring ownership before invoking user code.
    const auto count = packets.Size();
    for (uint32_t i = 0; i < count; ++i) {
        const auto packet = packets.RemoveAtBegin();
        packets.Append(packet);
        const auto buffer = packet.Buffer();
        if (!tun->callback || !tun->callback(tun->context, buffer.data(), buffer.Length()))
            counters_->tun_dropped.fetch_add(1, std::memory_order_relaxed);
    }
}

void TunnelController::Decapsulate(VpnPacketBuffer const &packet) {
    counters_->link_read.fetch_add(1, std::memory_order_relaxed);
    const auto buffer = packet.Buffer();
    std::function<void(const uint8_t *, size_t)> receive;
    { std::lock_guard lock(input_mutex_); receive = link_receive_; }
    if (!receive) return;
    receive(buffer.data(), buffer.Length());
}

} // namespace Partout

// ref is a retained channel context owned by the daemon bindings.
static Partout::TunnelController *get_controller(void *ref) {
    return static_cast<Partout::TunnelController *>(ref);
}

extern "C" {

void winrt_tun_free(winrt_tun tun) {
    if (!tun) return;
    winrt_tun_stop_writes(tun);
    winrt_tun_set_on_receive(tun, nullptr, nullptr);
    delete tun;
}

bool winrt_tun_set_on_receive(winrt_tun tun, winrt_tun_on_receive callback, void *context) {
    if (!tun) return false;
    std::lock_guard lock(tun->state->receive_mutex);
    if (callback && tun->state->callback) return false;
    tun->state->callback = callback;
    tun->state->context = context;
    return true;
}

void winrt_tun_stop_writes(winrt_tun tun) {
    if (!tun) return;
    tun->state->writes_stopped.store(true);
}

int32_t winrt_tun_write(winrt_tun tun, const uint8_t *bytes, size_t length) {
    if (!tun) return E_INVALIDARG;
    const auto state = tun->state;
    std::lock_guard lock(state->write_mutex);
    if (state->writes_stopped.load()) return E_ABORT;
    const auto result = write_channel(state->channel, bytes, length, false);
    (result == 0 ? state->counters->tun_write : state->counters->tun_write_failed).fetch_add(1, std::memory_order_relaxed);
    return result;
}

// FIXME: ###, Windows, Retain and notify the tunnel controller delegate.
void winrt_tun_ctrl_set_delegate(void *ref, const winrt_tun_ctrl_delegate *delegate) {
    winrt_log(WinrtLogDebug, "tun: ctrl_set_delegate(%p, %p)", ref, delegate);
}

bool winrt_tun_ctrl_configure_sockets(void *ref, const winrt_socket *sockets, size_t count) {
    if (count && !sockets) return false;
    const auto controller = get_controller(ref);
    for (size_t i = 0; i < count; ++i) {
        if (!sockets[i]) return false;
        if (controller && !controller->Associate(&sockets[i]->handle)) return false;
    }
    return true;
}
winrt_tun winrt_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)uuid;
    const auto controller = get_controller(ref);
    if (!controller) return nullptr;
    try { return controller->Open(info_json); }
    catch (...) { return nullptr; }
}
// FIXME: ###, Windows, Publish tunnel snapshots to the host.
void winrt_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    winrt_log(WinrtLogDebug, "tun: ctrl_report_snapshot(%p, %p)", ref, snapshot_json);
}

// FIXME: ###, Windows, Publish environment updates to the host.
void winrt_tun_ctrl_set_environment_value(void *ref, const char *key, const char *value) {
    winrt_log(WinrtLogDebug, "tun: ctrl_set_environment_value(%p, %p, %p)", ref, key, value);
}

// FIXME: ###, Windows, Honor kill_switch when clearing tunnel settings.
void winrt_tun_ctrl_clear_tunnel(void *ref, bool kill_switch) {
    winrt_log(WinrtLogDebug, "tun: ctrl_clear_tunnel(%p, %d)", ref, kill_switch);
    const auto controller = get_controller(ref);
    if (!controller) return;
    controller->Stop();
}

// FIXME: ###, Windows, Cancel the VPN channel and report error_message.
void winrt_tun_ctrl_cancel_tunnel(void *ref, const char *error_message) {
    winrt_log(WinrtLogDebug, "tun: ctrl_cancel_tunnel(%p, %p)", ref, error_message);
}

}
