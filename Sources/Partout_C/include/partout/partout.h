/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>

typedef struct __partout_tun_ctrl {
    void *ref;
    void (*test_working_wrapper)(struct __partout_tun_ctrl *thiz);
    void *(*set_tunnel)(struct __partout_tun_ctrl *thiz,
                        const char *info_json);
    void (*configure_sockets)(struct __partout_tun_ctrl *thiz,
                              const int *fds, const size_t fds_len);
    void (*clear_tunnel)(struct __partout_tun_ctrl *thiz,
                         void *tun_impl);
} partout_tun_ctrl;

partout_tun_ctrl partout_tun_ctrl_make(void *ref);
