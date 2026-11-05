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
#include <sys/uio.h>
#include <unistd.h>
#include "portable/endian.h"

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
