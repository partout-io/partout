// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "tun_settings.h"
#include <windows.h>
#include "winrt/tun.h"
#include "winrt/log.h"
#include "tun_ctrl.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Storage.Streams.h>
#include <atomic>
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
    bool independent_udp = false;
    std::shared_ptr<WinrtPacketCounters> counters;
    std::mutex receive_mutex;
    winrt_tun_on_receive callback = nullptr;
    void *context = nullptr;
    std::mutex write_mutex;
    std::atomic<bool> writes_stopped{false};

    explicit WinrtTun(VpnChannel const &value) : channel(value) {}
};

struct WinrtTunHandle { std::shared_ptr<WinrtTun> state; };

extern "C" void winrt_tun_free(winrt_tun tun) {
    if (!tun) return;
    winrt_tun_stop_writes(tun);
    winrt_tun_set_on_receive(tun, nullptr, nullptr);
    delete tun;
}

extern "C" bool winrt_tun_set_on_receive(winrt_tun tun, winrt_tun_on_receive callback, void *context) {
    if (!tun) return false;
    std::lock_guard lock(tun->state->receive_mutex);
    if (callback && tun->state->callback) return false;
    tun->state->callback = callback;
    tun->state->context = context;
    return true;
}

extern "C" void winrt_tun_stop_writes(winrt_tun tun) { tun->state->writes_stopped.store(true); }

static int32_t write_channel(VpnChannel const &channel, const uint8_t *bytes, size_t length, bool send) {
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
        return 0;
    } catch (...) {
        const auto error = to_hresult().value;
        winrt_log(WinrtLogError, "WinRT %s write failed during %s: HRESULT 0x%08x, length=%zu, capacity=%u",
            send ? "link" : "TUN", stage, static_cast<unsigned int>(error), length, capacity);
        // Return an unused pool buffer even if preparing the packet failed.
        if (packet) try {
            packet.Buffer().Length(0);
            append(packet);
            flush();
        } catch (...) {}
        return error;
    }
}

extern "C" int32_t winrt_tun_write(winrt_tun tun, const uint8_t *bytes, size_t length) {
    if (!tun) return E_INVALIDARG;
    const auto state = tun->state;
    std::lock_guard lock(state->write_mutex);
    if (state->writes_stopped.load()) return E_ABORT;
    const auto result = write_channel(state->channel, bytes, length, false);
    (result == 0 ? state->counters->tun_write : state->counters->tun_write_failed).fetch_add(1, std::memory_order_relaxed);
    return result;
}

PartoutTunnelController::PartoutTunnelController(VpnChannel const &channel)
    : channel_(channel), counters_(std::make_shared<WinrtPacketCounters>()) {}

PartoutTunnelController::~PartoutTunnelController() { Stop(); }

bool PartoutTunnelController::Associate(winrt_socket socket) noexcept {
    try {
        const auto transport = winrt_socket_transport(socket);
        if (!channel_ || !transport) return false;
        if (transport_ == transport) return true;
        channel_.AssociateTransport(transport, nullptr);
        transport_ = transport;
        socket_ = socket;
        std::lock_guard lock(input_mutex_);
        link_receive_ = winrt_socket_channel_receiver(socket);
        return true;
    } catch (...) {
        winrt_log(WinrtLogError, "PartoutTunnelController.Associate failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return false;
    }
}

bool PartoutTunnelController::Start(const char *info_json) noexcept {
    try {
        if (!channel_ || !transport_) return false;
        if (started_) return true;
        const auto settings = partout::windows::TunnelSettings::parse(info_json, idle_transport_ ? 1420 : 1400);
        if (!idle_transport_) winrt_socket_take_over(socket_);
        // Windows requires null for an absent address family, not an empty view.
        channel_.StartWithMainTransport(
            settings.ipv4.Size() ? settings.ipv4.GetView() : nullptr,
            settings.ipv6.Size() ? settings.ipv6.GetView() : nullptr,
            VpnInterfaceId{nullptr}, settings.routes, settings.domains,
            settings.mtu, settings.maxFrame(), false, transport_);
        started_ = true;
        winrt_socket_set_channel_writer(socket_, [channel = channel_, counters = counters_](const uint8_t *bytes, size_t length) {
            const auto result = write_channel(channel, bytes, length, true);
            (result == 0 ? counters->link_send : counters->link_send_failed).fetch_add(1, std::memory_order_relaxed);
            return result;
        });
        winrt_log(WinrtLogDebug, "PartoutTunnelController: Started (IPv4=%u, IPv6=%u, MTU=%u)",
            settings.ipv4.Size(), settings.ipv6.Size(), settings.mtu);
        return true;
    } catch (hresult_error const &error) {
        winrt_log(WinrtLogError, "PartoutTunnelController.Start failed: HRESULT 0x%08x (%ls)",
            static_cast<unsigned int>(error.code().value), error.message().c_str());
        return false;
    } catch (...) {
        winrt_log(WinrtLogError, "PartoutTunnelController.Start failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return false;
    }
}

void PartoutTunnelController::Stop() noexcept {
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
    if (!started_) return;
    try {
        std::unique_lock<std::mutex> writes;
        if (tun) writes = std::unique_lock(tun->write_mutex);
        channel_.Stop();
        started_ = false;
    } catch (...) {
        winrt_log(WinrtLogError, "PartoutTunnelController.Stop failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
    }
    winrt_log(WinrtLogNotice,
        "VPN packets (controller totals): TUN read=%llu, TUN dropped=%llu, link send=%llu, link send failed=%llu, link read=%llu, TUN write=%llu, TUN write failed=%llu",
        counters_->tun_read.load(), counters_->tun_dropped.load(), counters_->link_send.load(),
        counters_->link_send_failed.load(), counters_->link_read.load(), counters_->tun_write.load(), counters_->tun_write_failed.load());
}

winrt_tun PartoutTunnelController::Open(const char *info_json) {
    auto state = std::make_shared<WinrtTun>(channel_);
    state->counters = counters_;
    auto handle = std::make_unique<WinrtTunHandle>(WinrtTunHandle{state});
    if (!Start(info_json)) return nullptr;
    state->independent_udp = static_cast<bool>(idle_transport_);
    std::lock_guard lock(input_mutex_);
    tun_ = std::move(state);
    return handle.release();
}

void PartoutTunnelController::Encapsulate(VpnPacketBufferList const &packets) {
    // Leave input buffers in the platform list: Windows reclaims them on return.
    std::shared_ptr<WinrtTun> tun;
    { std::lock_guard lock(input_mutex_); tun = tun_; }
    const auto first = counters_->tun_read.fetch_add(packets.Size(), std::memory_order_relaxed);
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
        if (tun->independent_udp && first + i < 8) {
            const auto bytes = buffer.data();
            const auto length = buffer.Length();
            const unsigned version = length ? bytes[0] >> 4 : 0;
            wchar_t source[INET6_ADDRSTRLEN]{}, destination[INET6_ADDRSTRLEN]{};
            if ((version == 4 && length >= 20) || (version == 6 && length >= 40)) {
                const auto family = version == 4 ? AF_INET : AF_INET6;
                InetNtopW(family, bytes + (version == 4 ? 12 : 8), source, INET6_ADDRSTRLEN);
                InetNtopW(family, bytes + (version == 4 ? 16 : 24), destination, INET6_ADDRSTRLEN);
            }
            winrt_log(WinrtLogNotice, "WinRT independent UDP TUN input: IPv%u %ls -> %ls, length=%u",
                version, source, destination, length);
        }
        if (!tun->callback || !tun->callback(tun->context, buffer.data(), buffer.Length()))
            counters_->tun_dropped.fetch_add(1, std::memory_order_relaxed);
    }
}

void PartoutTunnelController::Decapsulate(VpnPacketBuffer const &packet) {
    counters_->link_read.fetch_add(1, std::memory_order_relaxed);
    const auto buffer = packet.Buffer();
    std::function<void(const uint8_t *, size_t)> receive;
    { std::lock_guard lock(input_mutex_); receive = link_receive_; }
    if (receive) receive(buffer.data(), buffer.Length());
}

// ref is a retained channel context owned by the daemon bindings.
static PartoutTunnelController *get_controller(void *ref) {
    return static_cast<PartoutTunnelController *>(ref);
}

// FIXME: ###, Windows, Retain and notify the tunnel controller delegate.
extern "C" void winrt_tun_ctrl_set_delegate(void *ref, const winrt_tun_ctrl_delegate *delegate) {
    winrt_log(WinrtLogDebug, "tun: ctrl_set_delegate(%p, %p)", ref, delegate);
}

extern "C" bool winrt_tun_ctrl_configure_sockets(void *ref, const winrt_socket *sockets, size_t count) {
    if (count && !sockets) return false;
    const auto controller = get_controller(ref);
    for (size_t i = 0; i < count; ++i) {
        if (!sockets[i]) return false;
        if (controller && !controller->Associate(sockets[i])) return false;
    }
    return true;
}
extern "C" winrt_tun winrt_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)uuid;
    const auto controller = get_controller(ref);
    try { return controller ? controller->Open(info_json) : nullptr; }
    catch (...) { return nullptr; }
}
// FIXME: ###, Windows, Publish tunnel snapshots to the host.
extern "C" void winrt_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    winrt_log(WinrtLogDebug, "tun: ctrl_report_snapshot(%p, %p)", ref, snapshot_json);
}

// FIXME: ###, Windows, Publish environment updates to the host.
extern "C" void winrt_tun_ctrl_set_environment_value(void *ref, const char *key, const char *value) {
    winrt_log(WinrtLogDebug, "tun: ctrl_set_environment_value(%p, %p, %p)", ref, key, value);
}

// FIXME: ###, Windows, Honor kill_switch when clearing tunnel settings.
extern "C" void winrt_tun_ctrl_clear_tunnel(void *ref, bool kill_switch) {
    winrt_log(WinrtLogDebug, "tun: ctrl_clear_tunnel(%p, %d)", ref, kill_switch);
    if (const auto controller = get_controller(ref)) controller->Stop();
}

// FIXME: ###, Windows, Cancel the VPN channel and report error_message.
extern "C" void winrt_tun_ctrl_cancel_tunnel(void *ref, const char *error_message) {
    winrt_log(WinrtLogDebug, "tun: ctrl_cancel_tunnel(%p, %p)", ref, error_message);
}
