/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */
#include "portable/tun.h"

struct __partout_tun_struct {
    void *ctx;
    partout_tun_callbacks callbacks;
};

pp_tun pp_tun_wrap_callbacks(void *ctx, const partout_tun_callbacks *callbacks) {
    if (!callbacks || !callbacks->read || !callbacks->write || !callbacks->close || !callbacks->watch) return NULL;
    pp_tun tun = calloc(1, sizeof(*tun));
    if (!tun) return NULL;
    tun->ctx = ctx;
    tun->callbacks = *callbacks;
    return tun;
}

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    tun->callbacks.close(tun->ctx);
    pp_free(tun);
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t len) {
    if (!tun || !dst || !len) return -1;
    return tun->callbacks.read(tun->ctx, dst, len);
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t len) {
    if (!tun || !src || !len) return -1;
    return tun->callbacks.write(tun->ctx, src, len);
}

pp_fd pp_tun_get_watch_fd(const pp_tun tun) {
    if (!tun) return pp_fd_invalid();
    return (pp_fd)tun->callbacks.watch(tun->ctx);
}
