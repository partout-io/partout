/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#ifdef __ANDROID_API__

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
    assert(impl && impl->fd > 0);

    printf("tun_android: Created tun device %d\n", impl->fd);
    return impl;
}

/* Do nothing, impl and fd are managed externally. */
void pp_tun_free(pp_tun tun) {
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    return read(tun->fd, dst, dst_len);
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    return write(tun->fd, src, src_len);
}

int pp_tun_fd(const pp_tun tun) {
    return tun->fd;
}

const char *pp_tun_name(const pp_tun tun) {
    return NULL;
}

#endif
