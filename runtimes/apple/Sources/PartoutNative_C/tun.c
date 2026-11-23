// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include "partout_apple.h"
#include <TargetConditionals.h>
#include <errno.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <unistd.h>

#if TARGET_OS_OSX
#include <sys/kern_control.h>
#include <net/if_utun.h>
#else
/* Redefine these manually because the <sys/kern_control.h>
 * header is not exposed to iOS/tvOS */
struct ctl_info {
    u_int32_t   ctl_id;
    char        ctl_name[96];
};
struct sockaddr_ctl {
    u_char      sc_len;
    u_char      sc_family;
    u_int16_t   ss_sysaddr;
    u_int32_t   sc_id;
    u_int32_t   sc_unit;
    u_int32_t   sc_reserved[5];
};
#endif

#define PARTOUT_IO_RETRY(result, operation) \
    do { result = (operation); } while (result < 0 && errno == EINTR)

#if defined(UTUN_CONTROL_NAME)
#define PARTOUT_UTUN_CONTROL_NAME UTUN_CONTROL_NAME
#else
#define PARTOUT_UTUN_CONTROL_NAME "com.apple.net.utun_control"
#endif

#if defined(CTLIOCGINFO)
#define PARTOUT_CTLIOCGINFO CTLIOCGINFO
#else
#define PARTOUT_CTLIOCGINFO 0xc0644e03UL
#endif

#define PARTOUT_TUN_NE_FD_MAX 1024

static int network_extension_fd(void) {
    struct ctl_info ctl_info = { 0 };
    snprintf(ctl_info.ctl_name, sizeof(ctl_info.ctl_name), "%s", PARTOUT_UTUN_CONTROL_NAME);
    for (int fd = 0; fd <= PARTOUT_TUN_NE_FD_MAX; ++fd) {
        struct sockaddr_ctl addr = { 0 };
        socklen_t len = sizeof(addr);
        int ret;
        PARTOUT_IO_RETRY(ret, getpeername(fd, (struct sockaddr *)&addr, &len));
        if (ret != 0 || addr.sc_family != AF_SYSTEM) {
            continue;
        }
        if (ctl_info.ctl_id == 0) {
            PARTOUT_IO_RETRY(ret, ioctl(fd, PARTOUT_CTLIOCGINFO, &ctl_info));
            if (ret != 0) {
                continue;
            }
        }
        if (addr.sc_id == ctl_info.ctl_id) {
            return fd;
        }
    }
    return -1;
}

partout_tun partout_tun_lookup(void) {
    const int fd = network_extension_fd();
    if (fd < 0) return NULL;
    const int duplicated = dup(fd);
    if (duplicated < 0) return NULL;
    partout_tun tun = partout_tun_wrap_fd(duplicated, true);
    if (!tun) close(duplicated);
    return tun;
}
