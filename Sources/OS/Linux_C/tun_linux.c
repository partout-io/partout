/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/unistd.h>
#include "portable/common.h"
#include "portable/tun.h"

pp_tun pp_tun_open() {
    const char *dev_path = "/dev/net/tun";
    int fd = -1;
    struct ifreq ifr = { 0 };

    /* Open the tun device for writing. Requires kernel support
     * but it's quite ubiquitous. Path is also expected to be
     * consistent across distros for coming from the kernel. */
    fd = open(dev_path, O_RDWR);
    if (fd < 0) {
        perror("open(tun)");
        goto failure;
    }

    /* Leave ifr.ifr_name empty to let the kernel retrieve
     * the first available device number */
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    if (ioctl(fd, TUNSETIFF, (void *)&ifr) < 0) {
        perror("ioctl(TUNSETIFF)");
        goto failure;
    }

    printf("tun_linux: Created tun device %s\n", ifr.ifr_name);
    return pp_tun_create(ifr.ifr_name, fd);

failure:
    if (fd != -1) close(fd);
    return NULL;
}
