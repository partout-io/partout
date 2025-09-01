/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

/* A tun device has a device name, and an associated socket to
 * do I/O. Usually a regular POSIX file descriptor. */
struct _pp_tun {
    const char *_Nonnull dev_name;
    pp_socket _Nonnull sock;
};

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

/* Return the device name. */
const char *pp_tun_name(pp_tun tun) {
    return tun->dev_name;
}

/* Return the socket associated to the tun device. */
pp_socket pp_tun_socket(pp_tun tun) {
    return tun->sock;
}
