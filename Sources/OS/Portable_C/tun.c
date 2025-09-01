/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <unistd.h>
#include "portable/common.h"
#include "portable/tun.h"

/* Create a structure for an open tun device. The tun object
 * takes ownership of the file descriptor. */
pp_tun pp_tun_create(const char *name, int fd) {
    pp_tun tun = pp_alloc(sizeof(pp_tun *));
    tun->fd = fd;
    tun->dev_name = pp_dup(name);
    return tun;
}

/* Free tun and the associated socket. */
void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    close(tun->fd);
    pp_free((void *)tun->dev_name);
    pp_free(tun);
}
