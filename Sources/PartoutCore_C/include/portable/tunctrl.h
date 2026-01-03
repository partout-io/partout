/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stddef.h>

typedef struct {
    const int *remote_fds;
    size_t remote_fds_len;
} pp_tun_ctrl_info;

void pp_tun_ctrl_test_working_wrapper(void *ref);
void *pp_tun_ctrl_set_tunnel(void *ref, const pp_tun_ctrl_info *info);
void pp_tun_ctrl_configure_sockets(void *ref, const int *fds, const size_t fds_len);
void pp_tun_ctrl_clear_tunnel(void *ref, void *tun_impl);
