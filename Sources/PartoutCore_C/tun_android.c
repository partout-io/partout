/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#if PARTOUT_ANDROID

#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include "portable/common.h"
#include "portable/tun.h"

/* Expect this struct from ctrl.set_tunnel(). */
struct _pp_tun {
    int fd;
};

/* Impl is the pp_tun struct as is. */
pp_tun pp_tun_create(const char *_Nonnull uuid, const void *_Nullable any_impl) {
    (void)uuid;
    if (!any_impl) return NULL;
    pp_tun impl = (pp_tun)any_impl;
    pp_assert(impl && impl->fd > 0);

    const int dup_fd = dup(impl->fd);
    if (dup_fd < 0) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "dup(tun): %s", strerror(errno));
        return NULL;
    }

    pp_tun tun = pp_alloc(sizeof(*tun));
    tun->fd = dup_fd;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_android: Duplicated tun device %d -> %d", impl->fd, dup_fd);
    return tun;
}

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    pp_tun_shutdown(tun);
    pp_free(tun);
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    if (!tun || tun->fd < 0) return -1;
    return read(tun->fd, dst, dst_len);
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    if (!tun || tun->fd < 0) return -1;
    return write(tun->fd, src, src_len);
}

void pp_tun_shutdown(const pp_tun tun) {
    if (!tun || tun->fd < 0) return;
    close(tun->fd);
    tun->fd = -1;
}

int pp_tun_fd(const pp_tun tun) {
    if (!tun) return -1;
    return tun->fd;
}

const char *pp_tun_name(const pp_tun tun) {
    (void)tun;
    return NULL;
}

#endif
