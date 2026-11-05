// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include "partout_posix.h"
#include <errno.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_OSX
#include <string.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <net/if_utun.h>
#elif defined(__linux__) && !defined(__ANDROID__)
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#endif

#define PARTOUT_IO_RETRY(result, operation) \
    do { result = (operation); } while (result < 0 && errno == EINTR)

partout_tun partout_tun_open(const char *uuid) {
    if (!uuid) return NULL;
#if defined(__APPLE__) && TARGET_OS_OSX
    const int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return NULL;
    struct ctl_info info = { 0 };
    strncpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    int ret;
    PARTOUT_IO_RETRY(ret, ioctl(fd, CTLIOCGINFO, &info));
    if (ret < 0) goto failure;
    struct sockaddr_ctl address = { 0 };
    address.sc_len = sizeof(address);
    address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL;
    address.sc_id = info.ctl_id;
    PARTOUT_IO_RETRY(ret, connect(fd, (struct sockaddr *)&address, sizeof(address)));
    if (ret < 0) goto failure;
#elif defined(__linux__) && !defined(__ANDROID__)
    int fd;
    PARTOUT_IO_RETRY(fd, open("/dev/net/tun", O_RDWR));
    if (fd < 0) return NULL;
    struct ifreq request = { 0 };
    request.ifr_flags = IFF_TUN | IFF_NO_PI;
    int ret;
    PARTOUT_IO_RETRY(ret, ioctl(fd, TUNSETIFF, &request));
    if (ret < 0) goto failure;
#else
    return NULL;
#endif
#if (defined(__APPLE__) && TARGET_OS_OSX) || (defined(__linux__) && !defined(__ANDROID__))
    partout_tun tun = partout_tun_wrap_fd(fd, true);
    if (tun) return tun;
failure:
    close(fd);
    return NULL;
#endif
}
