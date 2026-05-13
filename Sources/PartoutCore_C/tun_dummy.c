/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

// FIXME: ###, Implement macOS, Linux, and Windows (placeholder now)

#if !PARTOUT_HAS_TUN
void pp_tun_ctrl_test_working(void *ref) {
    (void)ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_test_working(%p), ref");
}

pp_tun pp_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)ref;
    (void)uuid;
    (void)info_json;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_set_tunnel(%p)", ref);
    return NULL;
}

void pp_tun_ctrl_configure_sockets(void *ref, const int *fds, const size_t fds_len) {
    (void)ref;
    (void)fds;
    (void)fds_len;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_configure_sockets(%p)", ref);
}

void pp_tun_ctrl_clear_tunnel(void *ref, pp_tun tun_impl) {
    (void)ref;
    (void)tun_impl;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_dummy: ctrl_clear_tunnel(%p)", ref);
}

void pp_tun_strg_install(void *ref,
                         const char *profile_json,
                         bool connect,
                         const char *options_json,
                         void *ctx,
                         pp_completion completion) {
    (void)ref;
    (void)profile_json;
    (void)options_json;
    (void)ctx;
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: strg_install(%p, %d)", ref, connect);
    if (completion) completion(NULL, 0);
}

void pp_tun_strg_uninstall(void *ref,
                           const char *profile_id,
                           void *ctx,
                           pp_completion completion) {
    (void)ref;
    (void)profile_id;
    (void)ctx;
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: strg_uninstall(%p)", ref);
    if (completion) completion(NULL, 0);
}

void pp_tun_strg_disconnect(void *ref,
                            const char *profile_id,
                            void *ctx,
                            pp_completion completion) {
    (void)ref;
    (void)profile_id;
    (void)ctx;
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_dummy: strg_disconnect(%p)", ref);
    if (completion) completion(NULL, 0);
}
#endif
