/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

// FIXME: ###, Implement macOS, Linux, and Windows (placeholder now)

#if !PARTOUT_ANDROID
void pp_tun_ctrl_test_working(void *ref) {
    (void)ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] test_working(%p), ref");
}

pp_tun pp_tun_ctrl_set_tunnel(void *ref, const char *info_json) {
    (void)ref;
    (void)info_json;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] set_tunnel(%p)", ref);
    return NULL;
}

void pp_tun_ctrl_configure_sockets(void *ref, const int *fds, const size_t fds_len) {
    (void)ref;
    (void)fds;
    (void)fds_len;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] configure_sockets(%p)", ref);
}

void pp_tun_ctrl_clear_tunnel(void *ref, pp_tun tun_impl) {
    (void)ref;
    (void)tun_impl;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] clear_tunnel(%p)", ref);
}
#endif
