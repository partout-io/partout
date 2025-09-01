/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if TARGET_OS_OSX

#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <stdio.h>
#include <string.h>
#include "portable/common.h"
#include "portable/socket.h"
#include "portable/tun.h"

pp_tun pp_tun_open() {
    struct sockaddr_ctl sc = { 0 };
    struct ctl_info ctl_info = { 0 };
    char ifname[IFNAMSIZ] = { 0 };
    socklen_t ifname_len = sizeof(ifname);
    int fd = -1;

    fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        perror("socket(PF_SYSTEM)");
        goto failure;
    }

    strncpy(ctl_info.ctl_name, UTUN_CONTROL_NAME, sizeof(ctl_info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &ctl_info) == -1) {
        perror("ioctl(CTLIOCGINFO)");
        goto failure;
    }

    sc.sc_id = ctl_info.ctl_id;
    sc.sc_len = sizeof(sc);
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_unit = 0;  // First free utunX
    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) == -1) {
        perror("connect(AF_SYSTEM, AF_SYS_CONTROL)");
        goto failure;
    }

    // Get actual name
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME,
                   ifname, &ifname_len) == -1) {
        perror("getsockopt(UTUN_OPT_IFNAME)");
        goto failure;
    }

    printf("tun_apple: Created utun device %s\n", ifname);
    return pp_tun_create(ifname, fd);

failure:
    if (fd != -1) close(fd);
    return NULL;
}

/* Platform-specific implementation to request a new tun device. */
pp_tun _Nullable pp_tun_open();

/* The first 4 bits of a local packet identify the IP family. */
static inline
uint32_t pp_tun_proto_for(uint8_t byte) {
    switch ((byte & 0xf0) >> 4) {
        case 4:
            return AF_INET;
        case 6:
            return AF_INET6;
        default:
            assert(false);
            return 0;
    }
}

ssize_t pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    uint32_t pi = 0; // 4-byte utun protocol header

    struct iovec iov[2];
    iov[0].iov_base = &pi;
    iov[0].iov_len  = sizeof(pi);
    iov[1].iov_base = dst;
    iov[1].iov_len  = dst_len;

    const int fd = (int)pp_socket_fd(pp_tun_socket(tun));
    const ssize_t read_len = readv(fd, iov, sizeof(iov) / sizeof(struct iovec));
    if (read_len < 0) return -1;
    if (read_len < sizeof(pi)) {
        fputs("Missing 4-byte utun packet header\n", stderr);
        return -1;
    }
    return read_len - (ssize_t)sizeof(pi);
}

ssize_t pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    const uint32_t pi = pp_endian_htonl(pp_tun_proto_for(*src));
    const size_t pi_len = sizeof(pi);

    struct iovec iov[2];
    iov[0].iov_base = (void *)&pi;
    iov[0].iov_len  = pi_len;
    iov[1].iov_base = (void *)src;
    iov[1].iov_len  = src_len;

    const int fd = (int)pp_socket_fd(pp_tun_socket(tun));
    const ssize_t written_len = writev(fd, iov, sizeof(iov) / sizeof(struct iovec));
    if (written_len < 0) return -1;
    if (written_len != pi_len + src_len) return -2;
    return written_len;
}

#endif
