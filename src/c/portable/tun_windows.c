/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */

#include "portable/conditionals.h"
#include "portable/tun.h"
#include "portable/tun_ctrl.h"
#include "portable/socket.h"

#if PARTOUT_WINDOWS && !PARTOUT_WINRT
/* Intentional fallback for Windows builds without the WinRT bridge, including
 * portable unit tests. These stubs provide the required cleanup and controller
 * symbols; transport configuration and tunnel creation are unavailable.
 */

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    pp_free(tun);
}

static void set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
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

static pp_tun set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)ref;
    (void)uuid;
    (void)info_json;
    return NULL;
}

static void report_snapshot(void *ref, const char *snapshot_json) {
    (void)ref;
    (void)snapshot_json;
}

static void set_environment_value(void *ref, const char *key, const char *value) {
    (void)ref;
    (void)key;
    (void)value;
}

static void clear_tunnel(void *ref, bool kill_switch) {
    (void)ref;
    (void)kill_switch;
}

static void cancel_tunnel(void *ref, const char *error_message) {
    (void)ref;
    (void)error_message;
}

pp_socket_configurator pp_socket_configurator_current(void *ref) {
    return (pp_socket_configurator){ .ctx = ref, .configure = configure_sockets };
}

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
    const pp_tun_ctrl_fnt functions = {
        .set_delegate = set_delegate,
        .set_tunnel = set_tunnel,
        .report_snapshot = report_snapshot,
        .set_environment_value = set_environment_value,
        .clear_tunnel = clear_tunnel,
        .cancel_tunnel = cancel_tunnel
    };
    return functions;
}

#endif // PARTOUT_WINDOWS
