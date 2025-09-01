/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

/* Create a structure for an open tun device. The tun object
 * takes ownership of the file descriptor. */
pp_tun pp_tun_create(const char *name, uint64_t fd) {
    pp_tun tun = pp_alloc(sizeof(pp_tun *));
    tun->dev_name = pp_dup(name);
    tun->sock = pp_socket_create(fd, true);
    return tun;
}

/* Free tun and the associated socket. */
void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    pp_free((void *)tun->dev_name);
    pp_socket_free(tun->sock);
    pp_free(tun);
}
