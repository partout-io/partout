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
    pp_fd fd;
    const char *dev_name;
};

pp_tun pp_tun_open(const char *uuid) {
    (void)uuid;
    const char *dev_path = "/dev/net/tun";
    int fd = -1;
    struct ifreq ifr = { 0 };

    /* Open the tun device for writing. Requires kernel support
     * but it's quite ubiquitous. Path is also expected to be
     * consistent across distros for coming from the kernel. */
    PP_IO_RETRY(fd, open(dev_path, O_RDWR));
    if (fd < 0) {
        pp_clog(PPLogLevelFault, "tun_linux: create(), open(tun)");
        goto failure;
    }

    /* Leave ifr.ifr_name empty to let the kernel retrieve
     * the first available device number */
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    int ret;
    PP_IO_RETRY(ret, ioctl(fd, TUNSETIFF, (void *)&ifr));
    if (ret < 0) {
        pp_clog(PPLogLevelFault, "tun_linux: create(), ioctl(TUNSETIFF)");
        goto failure;
    }

    pp_clog_v(PPLogLevelInfo, "tun_linux: Created tun device %s", ifr.ifr_name);
    pp_tun tun = pp_alloc(sizeof(*tun));
    tun->fd = fd;
    tun->dev_name = pp_dup(ifr.ifr_name);
    return tun;

failure:
    if (fd != -1) close(fd);
    return NULL;
}

void pp_tun_free_and_close(pp_tun tun, bool and_close) {
    if (!tun) return;
    if (and_close) {
        pp_tun_close(tun);
    }
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
    return pp_tun_handle_result(ret);
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    if (!tun || tun->fd < 0) return -1;
    if (!src || src_len == 0) return -1;
    int ret;
    PP_IO_RETRY(ret, write(tun->fd, src, src_len));
    return pp_tun_handle_result(ret);
}

void pp_tun_close(const pp_tun tun) {
    if (!tun || tun->fd < 0) return;
    close(tun->fd);
    tun->fd = -1;
}

pp_fd pp_tun_get_watch_fd(const pp_tun tun) {
    if (!tun) return -1;
    return tun->fd;
}

const char *pp_tun_name(const pp_tun tun) {
    return tun->dev_name;
}

static void pp_tun_ctrl_set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate) {
    (void)ref;
    (void)delegate;
    pp_clog_v(PPLogLevelDebug, "tun_linux: ctrl_set_delegate(%p, %p)", ref, delegate);
}

static pp_tun pp_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json) {
    (void)ref;
    (void)uuid;
    (void)info_json;
    pp_clog_v(PPLogLevelInfo, "tun_linux: ctrl_set_tunnel(%p)", ref);
    return pp_tun_open(uuid);
}

static bool pp_tun_ctrl_configure_sockets(void *ref, const pp_reachability *info,
                                          const pp_socket_fd *fds, const size_t fds_len) {
    (void)ref;
    (void)info;
    (void)fds;
    (void)fds_len;
    pp_clog_v(PPLogLevelInfo, "tun_linux: ctrl_configure_sockets(%p)", ref);
    return true;
}

static void pp_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json) {
    (void)ref;
    (void)snapshot_json;
}

static void pp_tun_ctrl_clear_tunnel(void *ref, bool kill_switch) {
    (void)ref;
    (void)kill_switch;
    pp_clog_v(PPLogLevelInfo, "tun_linux: ctrl_clear_tunnel(%p)", ref);
}

static void pp_tun_ctrl_cancel_tunnel(void *ref, const char *error_code) {
    (void)ref;
    (void)error_code;
    pp_clog_v(PPLogLevelInfo, "tun_linux: ctrl_cancel_tunnel(%p)", ref);
}

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
    pp_tun_ctrl_fnt fnt = {
        .set_delegate = pp_tun_ctrl_set_delegate,
        .set_tunnel = pp_tun_ctrl_set_tunnel,
        .configure_sockets = pp_tun_ctrl_configure_sockets,
        .report_snapshot = pp_tun_ctrl_report_snapshot,
        .clear_tunnel = pp_tun_ctrl_clear_tunnel,
        .cancel_tunnel = pp_tun_ctrl_cancel_tunnel
    };
    return fnt;
}

#endif
