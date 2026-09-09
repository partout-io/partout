// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "portable/tun_ctrl_winrt.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Vpn;

PartoutTunnelController::PartoutTunnelController(VpnChannel const &channel)
    : channel_(channel) {}

PartoutTunnelController::~PartoutTunnelController() { Stop(); }

bool PartoutTunnelController::Associate(pp_socket_fd fd) noexcept {
    try {
        if (!channel_ || !fd) return false;
        const auto socket = reinterpret_cast<const pp_winrt_socket *>(fd);
        const auto raw_transport = pp_winrt_socket_get_transport(socket);
        if (!raw_transport) return false;
        IInspectable transport{nullptr};
        copy_from_abi(transport, raw_transport);
        channel_.AddAndAssociateTransport(transport, nullptr);
        transport_ = transport;
        pp_clog(PPLogLevelDebug, "PartoutTunnelController: Associated transport");
        return true;
    } catch (...) {
        pp_clog_v(PPLogLevelError, "PartoutTunnelController.Associate failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return false;
    }
}

bool PartoutTunnelController::Start(const char *info_json) noexcept {
    // FIXME: ###, Derive addresses, routes, DNS and MTU from info_json.
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
        pp_clog(PPLogLevelDebug, "PartoutTunnelController: Started (placeholder settings)");
        return true;
    } catch (...) {
        pp_clog_v(PPLogLevelError, "PartoutTunnelController.Start failed: HRESULT 0x%08x",
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
        pp_clog_v(PPLogLevelError, "PartoutTunnelController.Stop failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
    }
}
