/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include "portable/common.h"
#include "portable/socket.h"

static pp_socket_fd local_invalid_fd(void);
static bool local_is_invalid_fd(pp_socket_fd fd);
static bool local_is_valid_socket(pp_socket sock);

#if PARTOUT_WINDOWS
#include "portable/socket_windows.h"
#else
#include "portable/socket_posix.h"
#endif

static bool local_platform_init(void);
static void local_print_error(const char *msg);
static void local_set_not_socket_error(void);
static void local_set_timeout_error(void);
static void local_set_reset_error(void);
static void local_set_error(int err);
static bool local_is_connect_pending(void);
static int local_close_fd(pp_socket_fd fd);
static int local_shutdown_fd(pp_socket_fd fd);
static int local_recv_fd(pp_socket_fd fd, void *dst, size_t dst_len);
static int local_send_fd(pp_socket_fd fd, const void *src, size_t src_len);
static int local_select_nfds(pp_socket_fd fd);
static bool local_init_socket(pp_socket sock);
static void local_cleanup_socket(pp_socket sock);
static pp_fd local_invalid_watch_fd(void);
static pp_fd local_socket_watch_fd(const pp_socket sock);

static int local_connect_with_timeout(pp_socket_fd fd,
                                      const struct sockaddr *addr,
                                      os_socklen_t addrlen,
                                      bool blocking,
                                      int timeout_ms);
static bool local_parse_numeric_addr(const char *ip_addr,
                                     uint16_t port,
                                     struct sockaddr_storage *addr,
                                     os_socklen_t *addrlen);
static void local_close_impl(pp_socket sock);

static bool local_is_invalid_fd(pp_socket_fd fd) {
    return fd == local_invalid_fd();
}

static bool local_is_valid_socket(pp_socket sock) {
    return sock &&
           !local_is_invalid_fd(sock->fd) &&
           pp_fd_is_valid(local_socket_watch_fd(sock));
}

/* Create a socket from a formerly opened file descriptor. */
static pp_socket pp_socket_create(pp_socket_fd fd) {
    pp_socket sock = pp_alloc(sizeof(*sock));
    sock->fd = (pp_socket_fd)fd;
    if (!local_init_socket(sock)) {
        pp_free(sock);
        return NULL;
    }
    return sock;
}

/* Open a socket to an IP address, an UDP/TCP protocol, and a port. Set
 * the non-blocking flag as an option, though the DNS resolution may
 * block regardless. */
pp_socket pp_socket_open(const char *ip_addr,
                         pp_socket_proto proto,
                         uint16_t port,
                         bool blocking,
                         int timeout_ms,
                         const pp_reachability *reachability,
                         pp_socket_configure configure,
                         void *configure_ctx) {
    int socktype = 0;
    struct addrinfo hints, *resolved = NULL;
    char port_str[16] = { 0 };
    pp_socket_fd new_fd = local_invalid_fd();
    int ipproto = 0;

    if (!local_platform_init()) {
        goto failure;
    }

    switch (proto) {
        case PPSocketProtoTCP:
            socktype = SOCK_STREAM;
            break;
        case PPSocketProtoUDP:
            socktype = SOCK_DGRAM;
            break;
    }

    struct sockaddr_storage numeric_addr;
    os_socklen_t numeric_addrlen = 0;
    if (local_parse_numeric_addr(ip_addr, port, &numeric_addr, &numeric_addrlen)) {
        new_fd = socket(numeric_addr.ss_family, socktype, ipproto);
        if (local_is_invalid_fd(new_fd)) {
            local_print_error("socket()");
            goto failure;
        }
        if (configure && !configure(configure_ctx, new_fd, reachability)) {
            local_print_error("configure()");
            goto failure;
        }
        if (local_connect_with_timeout(new_fd,
                                       (const struct sockaddr *)&numeric_addr,
                                       numeric_addrlen,
                                       blocking,
                                       timeout_ms) != 0) {
            local_print_error("connect()");
            goto failure;
        }
        pp_socket sock = pp_socket_create(new_fd);
        if (!sock) {
            goto failure;
        }
        return sock;
    }

    pp_zero(&hints, sizeof(hints));
    hints.ai_family = AF_UNSPEC;   // IPv4 or IPv6
    hints.ai_socktype = socktype;
    switch (proto) {
        case PPSocketProtoTCP:
            ipproto = IPPROTO_TCP;
            break;
        case PPSocketProtoUDP:
            ipproto = IPPROTO_UDP;
            break;
    }
    hints.ai_protocol = ipproto;
#ifdef AI_NUMERICSERV
    hints.ai_flags = AI_NUMERICSERV;
#endif

    snprintf(port_str, sizeof(port_str), "%u", port);
    int ret;
#if PARTOUT_ANDROID
    if (!reachability || reachability->network_handle <= 0) {
        local_print_error("android_getaddrinfofornetwork(): missing network handle");
        goto failure;
    }
    ret = android_getaddrinfofornetwork(reachability->network_handle, ip_addr, port_str, &hints, &resolved);
#else
    (void)reachability;
    ret = getaddrinfo(ip_addr, port_str, &hints, &resolved);
#endif
    if (ret != 0) {
        local_print_error("getaddrinfo()");
        goto failure;
    }

    // Loop through resolved to find first working socket
    for (struct addrinfo *p = resolved; p != NULL; p = p->ai_next) {
        new_fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (local_is_invalid_fd(new_fd)) {
            local_print_error("socket()");
            continue;
        }
        if (configure && !configure(configure_ctx, new_fd, reachability)) {
            local_print_error("configure()");
            goto failure;
        }
        const int ret = local_connect_with_timeout(new_fd,
                                                   p->ai_addr,
                                                   (os_socklen_t)p->ai_addrlen,
                                                   blocking,
                                                   timeout_ms);
        if (ret != 0) {
            local_close_fd(new_fd);
            new_fd = local_invalid_fd();
            local_print_error("connect()");
            continue;
        }
        // Exit loop on first success
        break;
    }
    freeaddrinfo(resolved);
    resolved = NULL;
    if (local_is_invalid_fd(new_fd)) {
        goto failure;
    }

    // Success
    pp_socket sock = pp_socket_create(new_fd);
    if (!sock) {
        goto failure;
    }
    return sock;

failure:
    if (resolved) freeaddrinfo(resolved);
    if (!local_is_invalid_fd(new_fd)) local_close_fd(new_fd);
    return NULL;
}

/* Close the native file descriptor without freeing the wrapper. */
void pp_socket_shutdown(pp_socket sock) {
    if (!local_is_valid_socket(sock)) return;
    (void)local_shutdown_fd(sock->fd);
}

/* Close the native file descriptor without freeing the wrapper. */
void pp_socket_close(pp_socket sock) {
    if (!sock) return;
    local_close_impl(sock);
}

/* Free the socket wrapper. */
void pp_socket_free_and_close(pp_socket sock, bool and_close) {
    if (!sock) return;
    if (and_close) {
        local_close_impl(sock);
    } else {
        local_cleanup_socket(sock);
    }
    pp_free(sock);
}

/* Read up to dst_len bytes, and return the amount of the actually read
 * bytes. Returns < 0 on failure. */
int pp_socket_read(pp_socket sock, uint8_t *dst, size_t dst_len) {
    if (!local_is_valid_socket(sock)) {
        local_set_not_socket_error();
        return -1;
    }

    while (true) {
        const int read_len = local_recv_fd(sock->fd, dst, dst_len);
        if (read_len < 0 && local_is_interrupted()) {
            continue;
        }
        if (read_len < 0) {
            /* If no messages are available at the socket, the receive call waits
             * for a message to arrive, unless the socket is nonblocking (see fcntl(2))
             * in which case the value -1 is returned and the external variable errno
             * set to EAGAIN. */
            if (local_is_wouldblock()) {
                return PPIOErrorWouldBlock;
            }
            local_print_error("recv()");
        }
        return read_len;
    }
}

/* Write src_len bytes, and repeat until fully written. Returns the amount
 * of written bytes, expected to always be src_len. Returns < 0 on failure. */
int pp_socket_write(pp_socket sock, const uint8_t *src, size_t src_len) {
    if (!local_is_valid_socket(sock)) {
        local_set_not_socket_error();
        return -1;
    }

    size_t offset = 0;
    while (offset < src_len) {
        const uint8_t *current_src = src + offset;
        const size_t remaining = src_len - offset;

        const int written_len = local_send_fd(sock->fd, current_src, remaining);
        if (written_len < 0) {
            if (local_is_interrupted()) {
                continue;
            }
            if (local_is_wouldblock()) {
                return offset > 0 ? (int)offset : PPIOErrorWouldBlock;
            }
            if (local_is_nobufs()) {
                return offset > 0 ? (int)offset : PPIOErrorNoBufs;
            }
            local_print_error("send()");
            return written_len;
        }
        if (written_len == 0) {
            local_set_reset_error();
            local_print_error("send()");
            return -1;
        }
        offset += (size_t)written_len;
    }
    return (int)offset;
}

bool pp_socket_set_buffers(pp_socket sock, int recvbuf_len, int sendbuf_len) {
    if (!local_is_valid_socket(sock)) {
        local_set_not_socket_error();
        return false;
    }

    bool did_set = true;
    if (recvbuf_len > 0) {
        if (setsockopt(sock->fd, SOL_SOCKET, SO_RCVBUF, (const char *)&recvbuf_len, sizeof(recvbuf_len)) < 0) {
            local_print_error("setsockopt(SO_RCVBUF)");
            did_set = false;
        }
    }
    if (sendbuf_len > 0) {
        if (setsockopt(sock->fd, SOL_SOCKET, SO_SNDBUF, (const char *)&sendbuf_len, sizeof(sendbuf_len)) < 0) {
            local_print_error("setsockopt(SO_SNDBUF)");
            did_set = false;
        }
    }
    return did_set;
}

/* Return the native file descriptor. */
pp_socket_fd pp_socket_get_fd(const pp_socket sock) {
    pp_assert(local_is_valid_socket(sock));
    return sock->fd;
}

/* Return the native watch file descriptor. */
pp_fd pp_socket_get_watch_fd(const pp_socket sock) {
    if (!local_is_valid_socket(sock)) {
        return local_invalid_watch_fd();
    }
    return local_socket_watch_fd(sock);
}

/* Cross-platform helpers. */

bool local_parse_numeric_addr(const char *ip_addr,
                              uint16_t port,
                              struct sockaddr_storage *addr,
                              os_socklen_t *addrlen) {
    struct sockaddr_in addr4;
    pp_zero(&addr4, sizeof(addr4));
    addr4.sin_family = AF_INET;
    addr4.sin_port = htons(port);
    if (inet_pton(AF_INET, ip_addr, &addr4.sin_addr) == 1) {
        pp_zero(addr, sizeof(*addr));
        memcpy(addr, &addr4, sizeof(addr4));
        *addrlen = sizeof(addr4);
        return true;
    }

    struct sockaddr_in6 addr6;
    pp_zero(&addr6, sizeof(addr6));
    addr6.sin6_family = AF_INET6;
    addr6.sin6_port = htons(port);
    if (inet_pton(AF_INET6, ip_addr, &addr6.sin6_addr) == 1) {
        pp_zero(addr, sizeof(*addr));
        memcpy(addr, &addr6, sizeof(addr6));
        *addrlen = sizeof(addr6);
        return true;
    }
    return false;
}

void local_close_impl(pp_socket sock) {
    if (!sock) {
        return;
    }
    local_cleanup_socket(sock);
    if (!local_is_invalid_fd(sock->fd)) {
        local_close_fd(sock->fd);
        sock->fd = local_invalid_fd();
    }
}

int local_connect_with_timeout(pp_socket_fd fd,
                               const struct sockaddr *addr,
                               os_socklen_t addrlen,
                               bool blocking,
                               int timeout_ms) {
    // Set non-blocking
    int original_flags = 0;
    if (pp_socket_set_nonblocking(fd, &original_flags) < 0) {
        return -1;
    }

    // At this point, this call will not block
    int ret = connect(fd, addr, addrlen);
    if (ret == 0) {
        // Connected immediately
        goto done;
    }
    // Tell real errors from non-blocking pending states
    if (!local_is_connect_pending() && !local_is_interrupted()) {
        local_print_error("connect()");
        return -1;
    }

    // Wait for socket to be writable
    while (true) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);

        struct timeval tv;
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;

        // Wait until timeout
        ret = select(local_select_nfds(fd), NULL, &wfds, NULL, &tv);
        if (ret == 0) {
            local_set_timeout_error();
            return -2;  // Timeout
        } else if (ret < 0) {
            if (local_is_interrupted()) continue;
            local_print_error("select()");
            return -1;  // Select error
        }
        break;
    }

    // Check SO_ERROR to see if connect succeeded
    int err = 0;
    os_socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char *)&err, &len) < 0) {
        local_print_error("getsockopt()");
        return -1;
    }
    if (err != 0) {
        local_set_error(err);
        return -1;
    }

done:
    // Store/restore blocking mode as needed
    if (blocking) {
        if (pp_socket_restore_blocking(fd, original_flags) < 0) {
            return -1;
        }
    }

    // Success
    return 0;
}
