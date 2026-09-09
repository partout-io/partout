/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/conditionals.h"

#if PARTOUT_WINDOWS
#include "portable/tun.h"

/* No tunnel backend is available in Windows builds without WinRT. */
pp_tun pp_tun_open(const char *uuid) {
    (void)uuid;
    return NULL;
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    (void)tun;
    (void)dst;
    (void)dst_len;
    return -1;
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    (void)tun;
    (void)src;
    (void)src_len;
    return -1;
}

void pp_tun_close(const pp_tun tun) {
    (void)tun;
}

void pp_tun_free_and_close(pp_tun tun, bool and_close) {
    (void)tun;
    (void)and_close;
}

pp_fd pp_tun_get_watch_fd(const pp_tun tun) {
    (void)tun;
    return pp_fd_invalid();
}

const char *pp_tun_name(const pp_tun tun) {
    (void)tun;
    return NULL;
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

#endif
