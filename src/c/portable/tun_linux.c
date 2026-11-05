/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

#if PARTOUT_LINUX

#include "portable/io_posix.h"
#include <stdlib.h>
#include <sys/unistd.h>

struct __partout_tun_struct {
    pp_fd fd;
    bool owned;
    const char *dev_name;
};

pp_tun pp_tun_wrap_fd(int fd, bool owned) {
    if (fd < 0) return NULL;
    pp_tun tun = calloc(1, sizeof(*tun));
    if (!tun) return NULL;
    tun->fd = fd;
    tun->owned = owned;
    return tun;
}

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    if (tun->owned && tun->fd >= 0) close(tun->fd);
    if (tun->dev_name) {
        pp_free((void *)tun->dev_name);
    }
    pp_free(tun);
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    if (!tun || tun->fd < 0) return -1;
    if (!dst || dst_len == 0) return -1;
    int ret;
    PP_IO_RETRY(ret, read(tun->fd, dst, dst_len));
    return pp_io_handle_result(ret);
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    if (!tun || tun->fd < 0) return -1;
    if (!src || src_len == 0) return -1;
    int ret;
    PP_IO_RETRY(ret, write(tun->fd, src, src_len));
    return pp_io_handle_result(ret);
}

pp_fd pp_tun_get_watch_fd(const pp_tun tun) {
    if (!tun) return -1;
    return tun->fd;
}

const char *pp_tun_name(const pp_tun tun) {
    if (!tun) return NULL;
    return tun->dev_name;
}

#endif
