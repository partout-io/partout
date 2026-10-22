// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
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

struct WinrtTun {
    VpnChannel channel;
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

extern "C" int32_t winrt_tun_write(winrt_tun tun, const uint8_t *bytes, size_t length) {
    if (!tun || !bytes || !length || length > UINT32_MAX) return E_INVALIDARG;
    const auto state = tun->state;
    std::lock_guard lock(state->write_mutex);
    if (state->writes_stopped.load()) return E_ABORT;
    VpnPacketBuffer packet{nullptr};
    try {
        packet = state->channel.GetVpnReceivePacketBuffer();
        const auto buffer = packet.Buffer();
        if (length > buffer.Capacity()) throw hresult_invalid_argument();
        memcpy(buffer.data(), bytes, length);
        buffer.Length(static_cast<uint32_t>(length));
        state->channel.AppendVpnReceivePacketBuffer(packet);
        packet = nullptr; // Ownership returned to the channel.
        state->channel.FlushVpnReceivePacketBuffers();
        return 0;
    } catch (...) {
        const auto error = to_hresult().value;
        // Return an unused pool buffer even if preparing the packet failed.
        if (packet) try {
            packet.Buffer().Length(0);
            state->channel.AppendVpnReceivePacketBuffer(packet);
            state->channel.FlushVpnReceivePacketBuffers();
        } catch (...) {}
        return error;
    }
}

PartoutTunnelController::PartoutTunnelController(VpnChannel const &channel)
    : channel_(channel) {}

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
    // FIXME: ###, Windows, Derive addresses, routes, DNS and MTU from info_json.
    (void)info_json;
    try {
        if (!channel_ || !transport_) return false;
        if (started_) return true;
        auto ipv4 = single_threaded_vector<HostName>();
        ipv4.Append(HostName{L"203.0.113.2"});
        auto ipv4_routes = single_threaded_vector<VpnRoute>();
        ipv4_routes.Append(VpnRoute{HostName{L"203.0.113.0"}, 24});
        VpnRouteAssignment routes;
        routes.Ipv4InclusionRoutes(ipv4_routes);
        VpnDomainNameAssignment domains;
        winrt_socket_take_over(socket_);
        channel_.StartWithMainTransport(
            ipv4.GetView(), nullptr, VpnInterfaceId{nullptr}, routes, domains,
            1500, 1600, false, transport_);
        started_ = true;
        winrt_log(WinrtLogDebug, "PartoutTunnelController: Started (placeholder settings)");
        return true;
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
}

winrt_tun PartoutTunnelController::Open(const char *info_json) {
    auto state = std::make_shared<WinrtTun>(channel_);
    auto handle = std::make_unique<WinrtTunHandle>(WinrtTunHandle{state});
    if (!Start(info_json)) return nullptr;
    std::lock_guard lock(input_mutex_);
    tun_ = std::move(state);
    return handle.release();
}

void PartoutTunnelController::Encapsulate(VpnPacketBufferList const &packets) {
    // Leave input buffers in the platform list: Windows reclaims them on return.
    std::shared_ptr<WinrtTun> tun;
    { std::lock_guard lock(input_mutex_); tun = tun_; }
    if (!tun) return;
    std::lock_guard lock(tun->receive_mutex);
    for (const auto &packet : packets) {
        const auto buffer = packet.Buffer();
        if (tun->callback) tun->callback(tun->context, buffer.data(), buffer.Length());
    }
}

void PartoutTunnelController::Decapsulate(VpnPacketBuffer const &packet) {
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
