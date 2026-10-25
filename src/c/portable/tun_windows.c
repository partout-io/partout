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
    if ((unsigned int)level >= sizeof(levels) / sizeof(levels[0])) return;
    pp_clog(levels[level], message);
}

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    winrt_tun_free((winrt_tun)tun);
}

static void on_reachability(void *context, bool reachable) {
    const pp_tun_ctrl_delegate *delegate = context;
    if (!delegate || !delegate->on_reachability) return;
    const pp_reachability info = { .reachable = reachable };
    delegate->on_reachability(delegate->ctx, &info);
}
static void on_better_path(void *context) {
    const pp_tun_ctrl_delegate *delegate = context;
    if (!delegate || !delegate->on_better_path) return;
    delegate->on_better_path(delegate->ctx);
}
static void set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    if (!delegate) {
        winrt_tun_ctrl_set_delegate(ref, NULL);
        return;
    }
    const winrt_tun_ctrl_delegate native = {
        .context = (void *)delegate,
        .on_reachability = on_reachability,
        .on_better_path = on_better_path
    };
    winrt_tun_ctrl_set_delegate(ref, &native);
}
static bool configure_sockets(void *ref, const pp_reachability *info, const pp_socket_fd *fds, size_t fds_len) {
    (void)info;
    if (fds_len && !fds) return false;
    for (size_t i = 0; i < fds_len; ++i) {
        const winrt_socket socket = (winrt_socket)(uintptr_t)fds[i];
        if (!winrt_tun_ctrl_configure_sockets(ref, &socket, 1)) return false;
    }
    return true;
}
static pp_tun set_tunnel(void *ref, const char *uuid, const char *info_json) {
    return (pp_tun)winrt_tun_ctrl_set_tunnel(ref, uuid, info_json);
}

static void report_snapshot(void *ref, const char *snapshot_json) {
    winrt_tun_ctrl_report_snapshot(ref, snapshot_json);
}

static void set_environment_value(void *ref, const char *key, const char *value) {
    winrt_tun_ctrl_set_environment_value(ref, key, value);
}

static void clear_tunnel(void *ref, bool kill_switch) {
    winrt_tun_ctrl_clear_tunnel(ref, kill_switch);
}

static void cancel_tunnel(void *ref, const char *error_message) {
    winrt_tun_ctrl_cancel_tunnel(ref, error_message);
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

#endif // PARTOUT_WINRT

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
#if PARTOUT_WINRT
    winrt_set_logger(bridge_log);
#endif
    const pp_tun_ctrl_fnt functions = {
        .set_delegate = set_delegate,
        .configure_sockets = configure_sockets,
        .set_tunnel = set_tunnel,
        .report_snapshot = report_snapshot,
        .set_environment_value = set_environment_value,
        .clear_tunnel = clear_tunnel,
        .cancel_tunnel = cancel_tunnel
    };
    return functions;
}

#endif // PARTOUT_WINDOWS
