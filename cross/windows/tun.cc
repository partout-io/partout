// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// MSVC does not support Clang's nullability annotations.
#if defined(_MSC_VER) && !defined(__clang__)
#pragma warning(push)
#pragma warning(disable: 4068)
#define _Nullable
#define _Nonnull
#endif

extern "C" {
#include "portable/tun_ctrl.h"
}

#if defined(_MSC_VER) && !defined(__clang__)
#undef _Nonnull
#undef _Nullable
#pragma warning(pop)
#endif

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

bool PartoutTunnelController::Associate(uintptr_t fd) noexcept {
    // FIXME: ###, Associate transports after the Windows socket backend rewrite.
    (void)fd;
    return false;
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

// ref is a retained channel context owned by the daemon bindings.
static PartoutTunnelController *get_controller(void *ref) {
    return static_cast<PartoutTunnelController *>(ref);
}

static void tun_ctrl_set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    pp_clog_v(PPLogLevelDebug, "tun: ctrl_set_delegate(%p, %p)", ref, delegate);
}

static bool tun_ctrl_configure_sockets(void *ref, const pp_reachability *info, const pp_socket_fd *fds, size_t fds_len) {
    pp_clog_v(PPLogLevelDebug, "tun: ctrl_configure_sockets(%p, %p, %p, %zu)", ref, info, fds, fds_len);
    const auto controller = get_controller(ref);
    if (!controller || !fds || fds_len == 0) return false;
    for (size_t i = 0; i < fds_len; ++i) {
        if (!controller->Associate(fds[i])) return false;
    }
    return true;
}

static pp_tun tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    pp_clog_v(PPLogLevelDebug, "tun: ctrl_set_tunnel(%p, %p, %p)", ref, uuid, info_json);
    const auto controller = get_controller(ref);
    if (!controller || !controller->Start(info_json)) return nullptr;
    // FIXME: ###, A packet-I/O pp_tun implementation is still pending.
    return nullptr;
}

static void tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    pp_clog_v(PPLogLevelDebug, "tun: ctrl_report_snapshot(%p, %p)", ref, snapshot_json);
}

static void tun_ctrl_set_environment_value(void *ref, const char *key, const char *value) {
    pp_clog_v(PPLogLevelDebug, "tun: ctrl_set_environment_value(%p, %p, %p)", ref, key, value);
}

static void tun_ctrl_clear_tunnel(void *ref, bool kill_switch) {
    pp_clog_v(PPLogLevelDebug, "tun: ctrl_clear_tunnel(%p, %d)", ref, kill_switch);
    if (const auto controller = get_controller(ref)) controller->Stop();
}

static void tun_ctrl_cancel_tunnel(void *ref, const char *error_message) {
    pp_clog_v(PPLogLevelDebug, "tun: ctrl_cancel_tunnel(%p, %p)", ref, error_message);
}

// The portable C ABI is the only entry point for controller callbacks.
extern "C" pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
    pp_tun_ctrl_fnt fnt{};
    fnt.set_delegate = tun_ctrl_set_delegate;
    fnt.configure_sockets = tun_ctrl_configure_sockets;
    fnt.set_tunnel = tun_ctrl_set_tunnel;
    fnt.report_snapshot = tun_ctrl_report_snapshot;
    fnt.set_environment_value = tun_ctrl_set_environment_value;
    fnt.clear_tunnel = tun_ctrl_clear_tunnel;
    fnt.cancel_tunnel = tun_ctrl_cancel_tunnel;
    return fnt;
}
