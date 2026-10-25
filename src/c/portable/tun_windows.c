/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */

#include "portable/conditionals.h"
#include "portable/tun.h"
#include "portable/tun_ctrl.h"

#if PARTOUT_WINDOWS
#if PARTOUT_WINRT

/* Partout owns this adapter. The WinRT backend imports no portable ABI headers. */
#include "winrt/tun.h"
#include "winrt/log.h"

static void bridge_log(winrt_log_level level, const char *message) {
    static const pp_log_level levels[] = {
        PPLogLevelFault, PPLogLevelError, PPLogLevelNotice, PPLogLevelInfo, PPLogLevelDebug
    };
    if ((unsigned int)level < sizeof(levels) / sizeof(levels[0])) pp_clog(levels[level], message);
}

void pp_tun_free(pp_tun tun) { winrt_tun_free((winrt_tun)tun); }

static void on_reachability(void *context, bool reachable) {
    const pp_tun_ctrl_delegate *delegate = context;
    const pp_reachability info = { .reachable = reachable };
    if (delegate->on_reachability) delegate->on_reachability(delegate->ctx, &info);
}
static void on_better_path(void *context) {
    const pp_tun_ctrl_delegate *delegate = context;
    if (delegate->on_better_path) delegate->on_better_path(delegate->ctx);
}
static void set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    if (!delegate) { winrt_tun_ctrl_set_delegate(ref, NULL); return; }
    const winrt_tun_ctrl_delegate native = {
        .context = (void *)delegate,
        .on_reachability = on_reachability,
        .on_better_path = on_better_path
    };
    winrt_tun_ctrl_set_delegate(ref, &native);
}
static bool configure_sockets(void *ref, const pp_reachability *info, const pp_socket_fd *fds, size_t count) {
    (void)info;
    if (count && !fds) return false;
    for (size_t i = 0; i < count; ++i) {
        const winrt_socket socket = (winrt_socket)(uintptr_t)fds[i];
        if (!winrt_tun_ctrl_configure_sockets(ref, &socket, 1)) return false;
    }
    return true;
}
static pp_tun set_tunnel(void *ref, const char *uuid, const char *info_json) {
    return (pp_tun)winrt_tun_ctrl_set_tunnel(ref, uuid, info_json);
}

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
    winrt_set_logger(bridge_log);
    const pp_tun_ctrl_fnt functions = {
        .set_delegate = set_delegate,
        .configure_sockets = configure_sockets,
        .set_tunnel = set_tunnel,
        .report_snapshot = winrt_tun_ctrl_report_snapshot,
        .set_environment_value = winrt_tun_ctrl_set_environment_value,
        .clear_tunnel = winrt_tun_ctrl_clear_tunnel,
        .cancel_tunnel = winrt_tun_ctrl_cancel_tunnel
    };
    return functions;
}

#else

/* Intentional fallback for Windows builds without the WinRT bridge, including
 * portable unit tests. These stubs provide the required cleanup and controller
 * symbols; transport configuration and tunnel creation are unavailable.
 */

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    pp_free(tun);
}

static void pp_tun_ctrl_set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    (void)ref;
    (void)delegate;
}

static bool pp_tun_ctrl_configure_sockets(void *ref, const pp_reachability *info,
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

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
    pp_tun_ctrl_fnt fnt = {
        .set_delegate = pp_tun_ctrl_set_delegate,
        .configure_sockets = pp_tun_ctrl_configure_sockets,
        .set_tunnel = pp_tun_ctrl_set_tunnel,
        .report_snapshot = pp_tun_ctrl_report_snapshot,
        .set_environment_value = pp_tun_ctrl_set_environment_value,
        .clear_tunnel = pp_tun_ctrl_clear_tunnel,
        .cancel_tunnel = pp_tun_ctrl_cancel_tunnel
    };
    return fnt;
}

#endif // PARTOUT_WINRT
#endif // PARTOUT_WINDOWS
