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
#include <chrono>
#include <cstring>
#include <mutex>
#include <utility>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Vpn;

namespace Partout {

// Retained by the controller, TUN handles and socket writer, without cycles.
class Tun::State {
public:
    VpnChannel channel;
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

    explicit State(VpnChannel const &value) : channel(value) {}
    int32_t write(const uint8_t *bytes, size_t length, bool send);
};

int32_t Tun::State::write(const uint8_t *bytes, size_t length, bool send) {
    if (!bytes || !length || length > UINT32_MAX) return E_INVALIDARG;
    const auto append = [&](VpnPacketBuffer const &packet) {
        if (send) channel.AppendVpnSendPacketBuffer(packet);
        else channel.AppendVpnReceivePacketBuffer(packet);
    };
    const auto flush = [&] {
        if (send) channel.FlushVpnSendPacketBuffers();
        else channel.FlushVpnReceivePacketBuffers();
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
    } catch (...) {
        const auto error = to_hresult().value;
        winrt_log(WinrtLogError, "WinRT %s write failed during %s: HRESULT 0x%08x, length=%zu, capacity=%u",
            send ? "link" : "TUN", stage, static_cast<unsigned int>(error), length, capacity);
        // Return an unused pool buffer even if preparing the packet failed.
        if (packet) {
            try {
                packet.Buffer().Length(0);
                append(packet);
                flush();
            } catch (...) {}
        }
        return error;
    }
    return 0;
}

Tun::Tun(std::shared_ptr<State> state) : state_(std::move(state)) {}

Tun::~Tun() noexcept {
    StopWrites();
    std::lock_guard lock(state_->receive_mutex);
    callback_ = nullptr;
    context_ = nullptr;
    // An older handle may be freed after Open publishes its replacement.
    if (state_->tun == this) state_->tun = nullptr;
}

bool Tun::SetOnReceive(winrt_tun_on_receive callback, void *context) {
    std::lock_guard lock(state_->receive_mutex);
    if (callback && callback_) return false;
    callback_ = callback;
    context_ = context;
    return true;
}

int32_t Tun::Write(const uint8_t *bytes, size_t length) {
    if (writes_stopped_) return E_ABORT;
    const auto result = state_->write(bytes, length, false);
    if (result) {
        ++state_->counters.tun_write_failed;
        return result;
    }
    ++state_->counters.tun_write;
    return 0;
}

void Tun::StopWrites() {
    writes_stopped_ = true;
}

TunnelController::TunnelController(VpnChannel const &channel)
    : state_(std::make_shared<Tun::State>(channel)) {}

TunnelController::~TunnelController() { Close(); }

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
        winrt_log(WinrtLogError, "Partout::TunnelController.Associate failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return false;
    }
    return true;
}

void TunnelController::AssociateUnconnected(Socket &socket) {
    // UDP sockets with multiple destinations keep their binds independent of the channel.
    // Keep the adapter across UDP bind replacement, including after Open.
    if (!udp_adapter_) {
        const auto profile = Connectivity::NetworkInformation::GetInternetConnectionProfile();
        if (!profile) throw hresult_error(E_FAIL, L"No physical network profile");
        udp_adapter_ = profile.NetworkAdapter();
    }
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
    } catch (...) { idle.Close(); throw; }
    idle_transport_ = idle;
    transport_ = idle;
    winrt_log(WinrtLogNotice, "WinRT independent UDP: idle channel transport ready");
}

winrt_tun TunnelController::Open(const char *info_json) {
    if (!state_->channel || !transport_) return nullptr;
    auto tun = std::unique_ptr<__winrt_tun_struct>(new __winrt_tun_struct{Tun{state_}});
    if (!started_) {
        const TunSettings settings{info_json};
        if (!idle_transport_) {
            auto receive = socket_->TakeOver([state = state_](const uint8_t *bytes, size_t length) {
                const auto result = state->write(bytes, length, true);
                if (result) {
                    ++state->counters.link_send_failed;
                    return result;
                }
                ++state->counters.link_send;
                return int32_t{0};
            });
            std::lock_guard lock(state_->receive_mutex);
            state_->link_receive = std::move(receive);
        }
        // Windows requires null for an absent address family, not an empty view.
        state_->channel.StartWithMainTransport(
            settings.IPv4().Size() ? settings.IPv4().GetView() : nullptr,
            settings.IPv6().Size() ? settings.IPv6().GetView() : nullptr,
            VpnInterfaceId{nullptr}, settings.Routes(), settings.Domains(),
            settings.MTU(), settings.MaxFrame(), false, transport_);
        started_ = true;
        socket_ = nullptr; // TakeOver's receiver retains the socket state.
        winrt_log(WinrtLogDebug, "Partout::TunnelController: Started (IPv4=%u, IPv6=%u, MTU=%u)",
            settings.IPv4().Size(), settings.IPv6().Size(), settings.MTU());
    }
    std::lock_guard lock(state_->receive_mutex);
    state_->tun = &tun->handle;
    return tun.release();
}

void TunnelController::Close() noexcept {
    {
        std::lock_guard lock(state_->receive_mutex);
        if (auto tun = std::exchange(state_->tun, nullptr)) {
            tun->StopWrites();
            tun->callback_ = nullptr;
            tun->context_ = nullptr;
        }
        state_->link_receive = nullptr;
    }
    if (started_) {
        try {
            state_->channel.Stop();
            started_ = false;
        } catch (...) {
            winrt_log(WinrtLogError, "Partout::TunnelController.Close failed: HRESULT 0x%08x",
                static_cast<unsigned int>(to_hresult().value));
        }
        Tun::State::Counters counters;
        { std::lock_guard lock(state_->receive_mutex); counters = state_->counters; }
        winrt_log(WinrtLogNotice,
            "VPN packets (controller totals): TUN read=%llu, TUN dropped=%llu, link send=%llu, link send failed=%llu, link read=%llu, TUN write=%llu, TUN write failed=%llu",
            counters.tun_read, counters.tun_dropped, counters.link_send,
            counters.link_send_failed, counters.link_read, counters.tun_write, counters.tun_write_failed);
    }
    // Release setup resources even if channel startup failed.
    try { if (idle_transport_) idle_transport_.Close(); } catch (...) {}
    idle_transport_ = nullptr;
    transport_ = nullptr;
    udp_adapter_ = nullptr;
    socket_ = nullptr;
}

void TunnelController::Encapsulate(VpnPacketBufferList const &packets) {
    const auto count = packets.Size();
    std::lock_guard lock(state_->receive_mutex);
    auto &counters = state_->counters;
    counters.tun_read += count;
    const auto tun = state_->tun;
    if (!tun || !tun->callback_) {
        counters.tun_dropped += count;
        return;
    }
    // VpnPacketBufferList's iterable view may be empty despite a nonzero Size.
    // Rotate through the native list, restoring ownership before invoking user code.
    // Windows reclaims these input buffers when the plugin callback returns.
    for (uint32_t i = 0; i < count; ++i) {
        const auto packet = packets.RemoveAtBegin();
        packets.Append(packet);
        const auto buffer = packet.Buffer();
        if (!tun->callback_(tun->context_, buffer.data(), buffer.Length()))
            ++counters.tun_dropped;
    }
}

void TunnelController::Decapsulate(VpnPacketBuffer const &packet) {
    std::lock_guard lock(state_->receive_mutex);
    ++state_->counters.link_read;
    if (!state_->link_receive) return;
    const auto buffer = packet.Buffer();
    state_->link_receive(buffer.data(), buffer.Length());
}

} // namespace Partout

// ref is a retained channel context owned by the daemon bindings.
static Partout::TunnelController *get_controller(void *ref) {
    return static_cast<Partout::TunnelController *>(ref);
}

extern "C" {

void winrt_tun_free(winrt_tun tun) {
    delete tun;
}

bool winrt_tun_set_on_receive(winrt_tun tun, winrt_tun_on_receive callback, void *context) {
    if (!tun) return false;
    return tun->handle.SetOnReceive(callback, context);
}

int32_t winrt_tun_write(winrt_tun tun, const uint8_t *bytes, size_t length) {
    if (!tun) return E_INVALIDARG;
    return tun->handle.Write(bytes, length);
}

void winrt_tun_stop_writes(winrt_tun tun) {
    if (!tun) return;
    tun->handle.StopWrites();
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
        if (controller && !controller->Associate(sockets[i]->handle)) return false;
    }
    return true;
}

winrt_tun winrt_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)uuid;
    const auto controller = get_controller(ref);
    if (!controller) return nullptr;
    try { return controller->Open(info_json); }
    catch (hresult_error const &error) {
        winrt_log(WinrtLogError, "Partout::TunnelController.Open failed: HRESULT 0x%08x (%ls)",
            static_cast<unsigned int>(error.code().value), error.message().c_str());
        return nullptr;
    } catch (...) {
        winrt_log(WinrtLogError, "Partout::TunnelController.Open failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return nullptr;
    }
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
    controller->Close();
}

// FIXME: ###, Windows, Cancel the VPN channel and report error_message.
void winrt_tun_ctrl_cancel_tunnel(void *ref, const char *error_message) {
    winrt_log(WinrtLogDebug, "tun: ctrl_cancel_tunnel(%p, %p)", ref, error_message);
}

}
