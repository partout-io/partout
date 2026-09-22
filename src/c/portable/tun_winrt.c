/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */

/* Partout owns this adapter. The WinRT backend imports no portable ABI headers. */
#include "portable/tun_ctrl.h"
#include "winrt/tun.h"
#include "winrt/log.h"

static void bridge_log(winrt_log_level level, const char *message) {
    static const pp_log_level levels[] = {
        PPLogLevelFault, PPLogLevelError, PPLogLevelNotice, PPLogLevelInfo, PPLogLevelDebug
    };
    if ((unsigned int)level < sizeof(levels) / sizeof(levels[0])) pp_clog(levels[level], message);
}

void pp_tun_free(pp_tun tun) { pp_free(tun); }

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
    (void)winrt_tun_ctrl_set_tunnel(ref, uuid, info_json);
    /* Channel startup is implemented; native packet TUN I/O is still pending.
     * Wrap a native TUN in the portable ABI here once that I/O exists. */
    return NULL;
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
