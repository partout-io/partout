/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

#if !PARTOUT_HAS_TUN
void pp_tun_free(pp_tun tun) {
    (void)tun;
    pp_clog(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: free()");
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    (void)tun;
    (void)dst;
    (void)dst_len;
    pp_clog(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: read()");
    return -1;
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    (void)tun;
    (void)src;
    (void)src_len;
    pp_clog(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: write()");
    return -1;
}

void pp_tun_shutdown(const pp_tun tun) {
    (void)tun;
    pp_clog(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: shutdown()");
}

int pp_tun_fd(const pp_tun tun) {
    (void)tun;
    pp_clog(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: fd()");
    return -1;
}

const char *pp_tun_name(const pp_tun tun) {
    (void)tun;
    pp_clog(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: name()");
    return NULL;
}

void pp_tun_ctrl_set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    (void)ref;
    (void)delegate;
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: ctrl_set_delegate(%p, %p)", ref, delegate);
}

pp_tun pp_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)ref;
    (void)uuid;
    (void)info_json;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_set_tunnel(%p)", ref);
    return NULL;
}

bool pp_tun_ctrl_configure_sockets(void *ref, const pp_reachability *info,
                                   const int *fds, const size_t fds_len) {
    (void)ref;
    (void)info;
    (void)fds;
    (void)fds_len;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_configure_sockets(%p)", ref);
    return true;
}

void pp_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    (void)ref;
    (void)snapshot_json;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_report_snapshot(%p)", ref);
}

void pp_tun_ctrl_clear_tunnel(void *ref, bool kill_switch) {
    (void)ref;
    (void)kill_switch;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_clear_tunnel(%p)", ref);
}

void pp_tun_ctrl_cancel_tunnel(void *ref, const char *error_code) {
    (void)ref;
    (void)error_code;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_cancel_tunnel(%p)", ref);
}

#endif
