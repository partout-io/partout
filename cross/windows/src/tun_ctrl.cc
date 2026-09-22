// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "winrt/tun.h"
#include "winrt/log.h"
#include "tun_ctrl.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Vpn;

PartoutTunnelController::PartoutTunnelController(VpnChannel const &channel)
    : channel_(channel) {}

PartoutTunnelController::~PartoutTunnelController() { Stop(); }

bool PartoutTunnelController::Associate(IInspectable const &transport) noexcept {
    try {
        if (!channel_ || !transport) return false;
        if (transport_ == transport) return true;
        channel_.AssociateTransport(transport, nullptr);
        transport_ = transport;
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
    if (!started_) return;
    try {
        channel_.Stop();
        started_ = false;
    } catch (...) {
        winrt_log(WinrtLogError, "PartoutTunnelController.Stop failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
    }
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
        if (controller && !controller->Associate(winrt_socket_transport(sockets[i]))) return false;
    }
    return true;
}
extern "C" bool winrt_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)uuid;
    const auto controller = get_controller(ref);
    return controller && controller->Start(info_json);
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
