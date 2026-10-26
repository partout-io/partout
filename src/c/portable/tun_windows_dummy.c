/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/conditionals.h"
#include "portable/tun.h"
#include "portable/tun_ctrl.h"
#include "portable/socket.h"

#if PARTOUT_WINDOWS

/* Intentional fallback for Windows builds without the WinRT bridge, including
 * portable unit tests. The build excludes this file when WinRT is linked.
 * These stubs provide the required cleanup and controller symbols: callbacks
 * are callable, but transport configuration and tunnel creation are unavailable.
 * Real Windows tunnel support belongs to the WinRT backend.
 */

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    pp_free(tun);
}

static void pp_tun_ctrl_set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    (void)ref;
    (void)delegate;
}

static bool configure_sockets(void *ref, const pp_reachability *info,
                                         const pp_socket_fd *fds, size_t fds_len) {
    (void)ref;
    (void)info;
    (void)fds;
    (void)fds_len;
    return false;
}

static pp_tun pp_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)ref;
    (void)uuid;
    (void)info_json;
    return NULL;
}

static void pp_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    (void)ref;
    (void)snapshot_json;
}

static void pp_tun_ctrl_set_environment_value(void *ref, const char *key, const char *value) {
    (void)ref;
    (void)key;
    (void)value;
}

static void pp_tun_ctrl_clear_tunnel(void *ref, bool kill_switch) {
    (void)ref;
    (void)kill_switch;
}

static void pp_tun_ctrl_cancel_tunnel(void *ref, const char *error_message) {
    (void)ref;
    (void)error_message;
}

pp_socket_configurator pp_socket_configurator_current(void *ref) {
    return (pp_socket_configurator){ .ctx = ref, .configure = configure_sockets };
}

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
    pp_tun_ctrl_fnt fnt = {
        .set_delegate = pp_tun_ctrl_set_delegate,
        .set_tunnel = pp_tun_ctrl_set_tunnel,
        .report_snapshot = pp_tun_ctrl_report_snapshot,
        .set_environment_value = pp_tun_ctrl_set_environment_value,
        .clear_tunnel = pp_tun_ctrl_clear_tunnel,
        .cancel_tunnel = pp_tun_ctrl_cancel_tunnel
    };
    return fnt;
}

#endif
