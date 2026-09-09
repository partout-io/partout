// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "portable/tun_winrt.h"
#include "portable/tun_ctrl_winrt.h"

// ref is a retained channel context owned by the daemon bindings.
static inline PartoutTunnelController *get_controller(void *ref) {
    return static_cast<PartoutTunnelController *>(ref);
}

void pp_winrt_tun_ctrl_set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    (void)ref;
    (void)delegate;
    pp_clog_v(PPLogLevelDebug, "tun_winrt: ctrl_set_delegate(%p, %p)", ref, delegate);
}

bool pp_winrt_tun_ctrl_configure_sockets(void *ref, const pp_reachability *info, const pp_socket_fd *fds, size_t fds_len) {
    (void)ref;
    (void)info;
    (void)fds;
    (void)fds_len;
    pp_clog_v(PPLogLevelDebug, "tun_winrt: ctrl_configure_sockets(%p, %p, %p, %zu)", ref, info, fds, fds_len);
    const auto controller = get_controller(ref);
    if (!controller || !fds || fds_len == 0) return false;
    for (size_t i = 0; i < fds_len; ++i) {
        if (!controller->Associate(fds[i])) return false;
    }
    return true;
}

pp_tun pp_winrt_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)uuid;
    (void)info_json;
    pp_clog_v(PPLogLevelDebug, "tun_winrt: ctrl_set_tunnel(%p, %p, %p)", ref, uuid, info_json);
    const auto controller = get_controller(ref);
    if (!controller || !controller->Start(info_json)) return nullptr;
    // FIXME: ###, A packet-I/O pp_tun implementation is still pending.
    return nullptr;
}

void pp_winrt_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    (void)ref;
    (void)snapshot_json;
    pp_clog_v(PPLogLevelDebug, "tun_winrt: ctrl_report_snapshot(%p, %p)", ref, snapshot_json);
}

void pp_winrt_tun_ctrl_set_environment_value(void *ref, const char *key, const char *value) {
    (void)ref;
    (void)key;
    (void)value;
    pp_clog_v(PPLogLevelDebug, "tun_winrt: ctrl_set_environment_value(%p, %p, %p)", ref, key, value);
}

void pp_winrt_tun_ctrl_clear_tunnel(void *ref, bool kill_switch) {
    (void)ref;
    (void)kill_switch;
    pp_clog_v(PPLogLevelDebug, "tun_winrt: ctrl_clear_tunnel(%p, %d)", ref, kill_switch);
    if (const auto controller = get_controller(ref)) controller->Stop();
}

void pp_winrt_tun_ctrl_cancel_tunnel(void *ref, const char *error_message) {
    (void)ref;
    (void)error_message;
    pp_clog_v(PPLogLevelDebug, "tun_winrt: ctrl_cancel_tunnel(%p, %p)", ref, error_message);
}