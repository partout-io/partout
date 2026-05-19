/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

// FIXME: #188, Implement Linux tun_ctrl

#if PARTOUT_LINUX

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/unistd.h>

struct __pp_tun_struct {
    int fd;
    const char *dev_name;
};

static
pp_tun pp_tun_create(const char *_Nonnull uuid) {
    (void)uuid;
    const char *dev_path = "/dev/net/tun";
    int fd = -1;
    struct ifreq ifr = { 0 };

    /* Open the tun device for writing. Requires kernel support
     * but it's quite ubiquitous. Path is also expected to be
     * consistent across distros for coming from the kernel. */
    fd = open(dev_path, O_RDWR);
    if (fd < 0) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_linux: create(), open(tun)");
        goto failure;
    }

    /* Leave ifr.ifr_name empty to let the kernel retrieve
     * the first available device number */
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    if (ioctl(fd, TUNSETIFF, (void *)&ifr) < 0) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_linux: create(), ioctl(TUNSETIFF)");
        goto failure;
    }

    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_linux: Created tun device %s", ifr.ifr_name);
    pp_tun tun = pp_alloc(sizeof(*tun));
    tun->fd = fd;
    tun->dev_name = pp_dup(ifr.ifr_name);
    return tun;

failure:
    if (fd != -1) close(fd);
    return NULL;
}

static
void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    pp_tun_shutdown(tun);
    pp_free((void *)tun->dev_name);
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
    return tun->dev_name;
}

pp_tun pp_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)ref;
    (void)uuid;
    (void)info_json;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_linux: ctrl_set_tunnel(%p)", ref);
    return NULL;
}

void pp_tun_ctrl_configure_sockets(void *ref, const int *fds, const size_t fds_len) {
    (void)ref;
    (void)fds;
    (void)fds_len;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_linux: ctrl_configure_sockets(%p)", ref);
}

void pp_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    (void)ref;
    (void)snapshot_json;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_linux: ctrl_report_snapshot(%p)", ref);
}

void pp_tun_ctrl_clear_tunnel(void *ref, pp_tun tun_impl) {
    (void)ref;
    (void)tun_impl;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_linux: ctrl_clear_tunnel(%p)", ref);
}

void pp_tun_ctrl_cancel_tunnel(void *ref, const char *error_message) {
    (void)ref;
    (void)error_message;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "tun_linux: ctrl_cancel_tunnel(%p)", ref);
}

#endif
