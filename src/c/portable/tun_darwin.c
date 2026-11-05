/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

#if PARTOUT_APPLE

#include "portable/io_posix.h"
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <net/if.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "portable/endian.h"

#if defined(UTUN_CONTROL_NAME)
#define PP_UTUN_CONTROL_NAME UTUN_CONTROL_NAME
#else
#define PP_UTUN_CONTROL_NAME "com.apple.net.utun_control"
#endif

#if defined(CTLIOCGINFO)
#define PP_CTLIOCGINFO CTLIOCGINFO
#else
#define PP_CTLIOCGINFO 0xc0644e03UL
#endif

#define PP_TUN_NE_FD_MAX 1024

struct __partout_tun_struct {
    pp_fd fd;
    const char *dev_name;
};

#if PARTOUT_MACOS
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <net/if_utun.h>

pp_tun pp_tun_open(const char *uuid) {
    (void)uuid;
    struct sockaddr_ctl sc = { 0 };
    struct ctl_info ctl_info = { 0 };
    char ifname[IFNAMSIZ] = { 0 };
    socklen_t ifname_len = sizeof(ifname);
    int fd = -1;

    fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        pp_clog(PPLogLevelFault, "tun_darwin: socket(PF_SYSTEM)");
        goto failure;
    }

    strncpy(ctl_info.ctl_name, UTUN_CONTROL_NAME, sizeof(ctl_info.ctl_name));
    int ret;
    PP_IO_RETRY(ret, ioctl(fd, CTLIOCGINFO, &ctl_info));
    if (ret < 0) {
        pp_clog(PPLogLevelFault, "tun_darwin: ioctl(CTLIOCGINFO)");
        goto failure;
    }

    sc.sc_id = ctl_info.ctl_id;
    sc.sc_len = sizeof(sc);
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_unit = 0;  // First free utunX
    PP_IO_RETRY(ret, connect(fd, (struct sockaddr *)&sc, sizeof(sc)));
    if (ret < 0) {
        pp_clog_v(PPLogLevelFault, "tun_darwin: connect(AF_SYSTEM, AF_SYS_CONTROL): %s", strerror(errno));
        goto failure;
    }

    // Get actual name
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME,
                   ifname, &ifname_len) == -1) {
        pp_clog(PPLogLevelFault, "tun_darwin: getsockopt(UTUN_OPT_IFNAME)");
        goto failure;
    }

    pp_clog_v(PPLogLevelInfo, "tun_darwin: Created utun device %s", ifname);
    pp_tun tun = pp_alloc(sizeof(*tun));
    tun->fd = fd;
    tun->dev_name = pp_dup(ifname);
    return tun;

failure:
    if (fd != -1) close(fd);
    return NULL;
}
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

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    if (tun->fd >= 0) close(tun->fd);
    if (tun->dev_name) {
        pp_free((void *)tun->dev_name);
    }
    pp_free(tun);
}

pp_tun pp_tun_lookup(void) {
    const int fd = pp_tun_network_extension_fd();
    if (fd < 0) return NULL;
    /* iOS/tvOS require the file descriptor to be duplicated. */
    const int dup_fd = dup(fd);
    if (dup_fd < 0) return NULL;
    pp_tun tun = pp_alloc(sizeof(*tun));
    tun->fd = dup_fd;
    tun->dev_name = NULL;
    return tun;
}

pp_fd pp_tun_network_extension_fd(void) {
    struct ctl_info ctl_info = { 0 };
    snprintf(ctl_info.ctl_name, sizeof(ctl_info.ctl_name), "%s", PP_UTUN_CONTROL_NAME);
    for (pp_fd fd = 0; fd <= PP_TUN_NE_FD_MAX; ++fd) {
        struct sockaddr_ctl addr = { 0 };
        socklen_t len = sizeof(addr);
        int ret;
        PP_IO_RETRY(ret, getpeername(fd, (struct sockaddr *)&addr, &len));
        if (ret != 0 || addr.sc_family != AF_SYSTEM) {
            continue;
        }
        if (ctl_info.ctl_id == 0) {
            PP_IO_RETRY(ret, ioctl(fd, PP_CTLIOCGINFO, &ctl_info));
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

/* The first 4 bits of a local packet identify the IP family. */
static inline
uint32_t pp_tun_proto_for(uint8_t byte) {
    const uint8_t header = (byte & 0xf0) >> 4;
    switch (header) {
        case 4:
            return AF_INET;
        case 6:
            return AF_INET6;
        default:
            pp_clog_v(PPLogLevelError, "tun_darwin: Unexpected utun packet header (%u)", header);
            return 0;
    }
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    if (!tun || tun->fd < 0) return -1;
    if (!dst || dst_len == 0) return -1;
    uint32_t pi = 0; // 4-byte utun protocol header

    struct iovec iov[2];
    iov[0].iov_base = &pi;
    iov[0].iov_len  = sizeof(pi);
    iov[1].iov_base = dst;
    iov[1].iov_len  = dst_len;

    int read_len;
    PP_IO_RETRY(read_len, (int)readv(tun->fd, iov, sizeof(iov) / sizeof(struct iovec)));
    if (read_len < 0) {
        return pp_io_handle_result(read_len);
    }
    if (read_len < (int)sizeof(pi)) {
        pp_clog(PPLogLevelError, "tun_darwin: Missing 4-byte utun packet header");
        return -1;
    }
    return read_len - (int)sizeof(pi);
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    if (!tun || tun->fd < 0) return -1;
    if (!src || src_len == 0) return -1;
    const uint32_t proto_byte = pp_tun_proto_for(*src);
    if (proto_byte == 0) return -1;
    const uint32_t pi = pp_endian_htonl(proto_byte);
    const size_t pi_len = sizeof(pi);

    struct iovec iov[2];
    iov[0].iov_base = (void *)&pi;
    iov[0].iov_len  = pi_len;
    iov[1].iov_base = (void *)src;
    iov[1].iov_len  = src_len;

    int written_len;
    PP_IO_RETRY(written_len, (int)writev(tun->fd, iov, sizeof(iov) / sizeof(struct iovec)));
    if (written_len < 0) {
        return pp_io_handle_result(written_len);
    }
    if (written_len != (int)(pi_len + src_len)) return -3;
    return (int)src_len;
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
