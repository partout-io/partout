/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stddef.h>

void pp_tun_ctrl_test_working_wrapper(void *ref);
void *pp_tun_ctrl_set_tunnel(void *ref, const char *info_json);
void pp_tun_ctrl_configure_sockets(void *ref, const int *fds, const size_t fds_len);
void pp_tun_ctrl_clear_tunnel(void *ref, void *tun_impl);
