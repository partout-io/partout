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
#include <net/if.h>
#include <net/if_utun.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
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

#endif
