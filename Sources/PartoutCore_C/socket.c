/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include "portable/common.h"
#include "portable/socket.h"

#if PARTOUT_WINDOWS
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET os_socket_fd;
typedef int os_socklen_t;
#define OS_INVALID_SOCKET INVALID_SOCKET
#define OS_SHUTDOWN_BOTH SD_BOTH
#define OS_SOCKET_ERROR SOCKET_ERROR
#else
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <arpa/inet.h>
#include <netdb.h>
typedef int os_socket_fd;
typedef socklen_t os_socklen_t;
#define OS_INVALID_SOCKET -1
#define OS_SHUTDOWN_BOTH SHUT_RDWR
#define OS_SOCKET_ERROR -1
#endif

static bool pp_socket_platform_init(void);
static void pp_socket_print_error(const char *msg);
static void pp_socket_set_not_socket_error(void);
static void pp_socket_set_timeout_error(void);
static void pp_socket_set_reset_error(void);
static void pp_socket_set_error(int err);
static bool pp_socket_is_interrupted(void);
static bool pp_socket_is_would_block(void);
static bool pp_socket_is_connect_pending(void);
static int pp_socket_close_fd(os_socket_fd fd);
static int pp_socket_shutdown_fd(os_socket_fd fd);
static int pp_socket_recv_fd(os_socket_fd fd, void *dst, size_t dst_len);
static int pp_socket_send_fd(os_socket_fd fd, const void *src, size_t src_len);
static int pp_socket_select_nfds(os_socket_fd fd);
static int pp_socket_set_nonblocking(os_socket_fd fd, int *original_flags);
static int pp_socket_restore_blocking(os_socket_fd fd, int original_flags);
static int pp_socket_connect_with_timeout(os_socket_fd fd,
                                          const struct sockaddr *addr,
                                          socklen_t addrlen,
                                          bool blocking,
                                          int timeout_ms);
static bool pp_socket_parse_numeric_addr(const char *ip_addr,
                                         uint16_t port,
                                         struct sockaddr_storage *addr,
                                         socklen_t *addrlen);
static void pp_socket_close_impl(pp_socket sock);
static bool pp_socket_wait(pp_socket sock, int timeout_ms, bool want_read, bool want_write);

/* Host a file descriptor with the specific platform type. POSIX systems
 * use int, whereas Windows uses SOCKET.  */
struct _pp_socket {
    os_socket_fd fd;
};

/* Create a socket from a formerly opened file descriptor. Use uint64_t to
 * cover the whole range of possible platform values. */
pp_socket pp_socket_create(uint64_t fd) {
    pp_socket sock = pp_alloc(sizeof(*sock));
    sock->fd = (os_socket_fd)fd;
    return sock;
}

/* Open a socket to an IP address, an UDP/TCP protocol, and a port. Set
 * the non-blocking flag as an option. Beware with Swift Concurrency that
 * this function is blocking regardless of the blocking argument. */
pp_socket pp_socket_open(const char *ip_addr,
                         pp_socket_proto proto,
                         uint16_t port,
                         bool blocking,
                         int timeout_ms) {
    struct addrinfo hints, *resolved = NULL;
    char port_str[16] = { 0 };
    os_socket_fd new_fd = OS_INVALID_SOCKET;
    int ipproto = 0;

    if (!pp_socket_platform_init()) {
        goto failure;
    }

    pp_zero(&hints, sizeof(hints));
    hints.ai_family = AF_UNSPEC;   // IPv4 or IPv6
    switch (proto) {
        case PPSocketProtoTCP:
            ipproto = IPPROTO_TCP;
            hints.ai_socktype = SOCK_STREAM;
            break;
        case PPSocketProtoUDP:
            ipproto = IPPROTO_UDP;
            hints.ai_socktype = SOCK_DGRAM;
            break;
    }
    hints.ai_protocol = ipproto;
#ifdef AI_NUMERICSERV
    hints.ai_flags = AI_NUMERICSERV;
#endif

    struct sockaddr_storage numeric_addr;
    socklen_t numeric_addrlen = 0;
    if (pp_socket_parse_numeric_addr(ip_addr, port, &numeric_addr, &numeric_addrlen)) {
        new_fd = socket(numeric_addr.ss_family, hints.ai_socktype, ipproto);
        if (new_fd == OS_INVALID_SOCKET) {
            pp_socket_print_error("socket()");
            goto failure;
        }
        if (pp_socket_connect_with_timeout(new_fd,
                                           (const struct sockaddr *)&numeric_addr,
                                           numeric_addrlen,
                                           blocking,
                                           timeout_ms) != 0) {
            pp_socket_print_error("connect()");
            goto failure;
        }
        return pp_socket_create(new_fd);
    }

    snprintf(port_str, sizeof(port_str), "%u", port);
    if (getaddrinfo(ip_addr, port_str, &hints, &resolved) != 0) {
        pp_socket_print_error("getaddrinfo()");
        goto failure;
    }

    // Loop through resolved to find first working socket
    for (struct addrinfo *p = resolved; p != NULL; p = p->ai_next) {
        new_fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (new_fd == OS_INVALID_SOCKET) {
            pp_socket_print_error("socket()");
            continue;
        }
        const int ret = pp_socket_connect_with_timeout(new_fd,
                                                       p->ai_addr,
                                                       (int)p->ai_addrlen,
                                                       blocking,
                                                       timeout_ms);
        if (ret != 0) {
            pp_socket_close_fd(new_fd);
            pp_socket_print_error("connect()");
            continue;
        }
        // Exit loop on first success
        break;
    }
    freeaddrinfo(resolved);
    if (new_fd == OS_INVALID_SOCKET) {
        goto failure;
    }

    // Success
    return pp_socket_create(new_fd);

failure:
    if (new_fd != OS_INVALID_SOCKET) pp_socket_close_fd(new_fd);
    return NULL;
}

/* Close the native file descriptor without freeing the wrapper. */
void pp_socket_shutdown(pp_socket sock) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) return;
    (void)pp_socket_shutdown_fd(sock->fd);
}

/* Close the native file descriptor without freeing the wrapper. */
void pp_socket_close(pp_socket sock) {
    if (!sock) return;
    pp_socket_close_impl(sock);
}

/* Free the socket wrapper. */
void pp_socket_free(pp_socket sock) {
    if (!sock) return;
    pp_socket_close_impl(sock);
    pp_free(sock);
}

/* Read up to dst_len bytes, and return the amount of the actually read
 * bytes. Returns < 0 on failure. */
int pp_socket_read(pp_socket sock, uint8_t *dst, size_t dst_len) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
        pp_socket_set_not_socket_error();
        return -1;
    }

    while (true) {
        const int read_len = pp_socket_recv_fd(sock->fd, dst, dst_len);
        if (read_len < 0 && pp_socket_is_interrupted()) {
            continue;
        }
        if (read_len < 0) {
            /* If no messages are available at the socket, the receive call waits
             * for a message to arrive, unless the socket is nonblocking (see fcntl(2))
             * in which case the value -1 is returned and the external variable errno
             * set to EAGAIN. */
            if (pp_socket_is_would_block()) {
                return 0;
            }
            pp_socket_print_error("recv()");
        }
        return read_len;
    }
}

/* Write src_len bytes, and repeat until fully written. Returns the amount
 * of written bytes, expected to always be src_len. Returns < 0 on failure. */
int pp_socket_write(pp_socket sock, const uint8_t *src, size_t src_len) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
        pp_socket_set_not_socket_error();
        return -1;
    }

    size_t offset = 0;
    while (offset < src_len) {
        const uint8_t *current_src = src + offset;
        const size_t remaining = src_len - offset;

        const int written_len = pp_socket_send_fd(sock->fd, current_src, remaining);
        if (written_len < 0) {
            if (pp_socket_is_interrupted()) {
                continue;
            }
            if (pp_socket_is_would_block()) {
                return offset > 0 ? (int)offset : 0;
            }
            pp_socket_print_error("send()");
            return written_len;
        }
        if (written_len == 0) {
            pp_socket_set_reset_error();
            pp_socket_print_error("send()");
            return -1;
        }
        offset += (size_t)written_len;
    }
    return (int)offset;
}

bool pp_socket_set_buffers(pp_socket sock, int recvbuf_len, int sendbuf_len) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
        pp_socket_set_not_socket_error();
        return false;
    }

    bool did_set = true;
    if (recvbuf_len > 0) {
        if (setsockopt(sock->fd, SOL_SOCKET, SO_RCVBUF, (const char *)&recvbuf_len, sizeof(recvbuf_len)) < 0) {
            pp_socket_print_error("setsockopt(SO_RCVBUF)");
            did_set = false;
        }
    }
    if (sendbuf_len > 0) {
        if (setsockopt(sock->fd, SOL_SOCKET, SO_SNDBUF, (const char *)&sendbuf_len, sizeof(sendbuf_len)) < 0) {
            pp_socket_print_error("setsockopt(SO_SNDBUF)");
            did_set = false;
        }
    }
    return did_set;
}

/* Wait until the socket is readable. Returns false on timeout or failure. */
bool pp_socket_wait_readable(pp_socket sock, int timeout_ms) {
    return pp_socket_wait(sock, timeout_ms, true, false);
}

/* Wait until the socket is writable. Returns false on timeout or failure. */
bool pp_socket_wait_writable(pp_socket sock, int timeout_ms) {
    return pp_socket_wait(sock, timeout_ms, false, true);
}

/* Return the native file descriptor. */
uint64_t pp_socket_fd(const pp_socket sock) {
    pp_assert(sock && sock->fd != OS_INVALID_SOCKET);
    return sock->fd;
}

#if PARTOUT_WINDOWS
static bool pp_socket_platform_init(void) {
    static int wsa_initialized = 0;
    if (!wsa_initialized) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            pp_socket_print_error("WSAStartup()");
            return false;
        }
        wsa_initialized = 1;
    }
    return true;
}

static void pp_socket_print_error(const char *msg) {
    pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "%s failed with error %d", msg, WSAGetLastError());
}

static void pp_socket_set_not_socket_error(void) {
    WSASetLastError(WSAENOTSOCK);
}

static void pp_socket_set_timeout_error(void) {
    WSASetLastError(WSAETIMEDOUT);
}

static void pp_socket_set_reset_error(void) {
    WSASetLastError(WSAECONNRESET);
}

static void pp_socket_set_error(int err) {
    WSASetLastError(err);
}

static bool pp_socket_is_interrupted(void) {
    return WSAGetLastError() == WSAEINTR;
}

static bool pp_socket_is_would_block(void) {
    return WSAGetLastError() == WSAEWOULDBLOCK;
}

static bool pp_socket_is_connect_pending(void) {
    const int err = WSAGetLastError();
    return err == WSAEWOULDBLOCK || err == WSAEINPROGRESS;
}

static int pp_socket_close_fd(os_socket_fd fd) {
    return closesocket(fd);
}

static int pp_socket_shutdown_fd(os_socket_fd fd) {
    return shutdown(fd, OS_SHUTDOWN_BOTH);
}

static int pp_socket_recv_fd(os_socket_fd fd, void *dst, size_t dst_len) {
    return (int)recv(fd, dst, (int)dst_len, 0);
}

static int pp_socket_send_fd(os_socket_fd fd, const void *src, size_t src_len) {
    return (int)send(fd, src, (int)src_len, 0);
}

static int pp_socket_select_nfds(os_socket_fd fd) {
    (void)fd;
    return 0;
}

static int pp_socket_set_nonblocking(os_socket_fd fd, int *original_flags) {
    (void)original_flags;
    u_long mode = 1;
    if (ioctlsocket(fd, FIONBIO, &mode) == OS_SOCKET_ERROR) {
        pp_socket_print_error("ioctlsocket()");
        return -1;
    }
    return 0;
}

static int pp_socket_restore_blocking(os_socket_fd fd, int original_flags) {
    (void)original_flags;
    u_long mode = 0;
    if (ioctlsocket(fd, FIONBIO, &mode) == OS_SOCKET_ERROR) {
        pp_socket_print_error("ioctlsocket()");
        return -1;
    }
    return 0;
}
#else
static bool pp_socket_platform_init(void) {
    return true;
}

static void pp_socket_print_error(const char *msg) {
    pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "%s failed: %s", msg, strerror(errno));
}

static void pp_socket_set_not_socket_error(void) {
    errno = EBADF;
}

static void pp_socket_set_timeout_error(void) {
    errno = ETIMEDOUT;
}

static void pp_socket_set_reset_error(void) {
    errno = EPIPE;
}

static void pp_socket_set_error(int err) {
    errno = err;
}

static bool pp_socket_is_interrupted(void) {
    return errno == EINTR;
}

static bool pp_socket_is_would_block(void) {
    return errno == EAGAIN || errno == EWOULDBLOCK;
}

static bool pp_socket_is_connect_pending(void) {
    return errno == EINPROGRESS;
}

static int pp_socket_close_fd(os_socket_fd fd) {
    return close(fd);
}

static int pp_socket_shutdown_fd(os_socket_fd fd) {
    return shutdown(fd, OS_SHUTDOWN_BOTH);
}

static int pp_socket_recv_fd(os_socket_fd fd, void *dst, size_t dst_len) {
    return (int)read(fd, dst, dst_len);
}

static int pp_socket_send_fd(os_socket_fd fd, const void *src, size_t src_len) {
    return (int)write(fd, src, src_len);
}

static int pp_socket_select_nfds(os_socket_fd fd) {
    return fd + 1;
}

static int pp_socket_set_nonblocking(os_socket_fd fd, int *original_flags) {
    *original_flags = fcntl(fd, F_GETFL, 0);
    if (*original_flags < 0) {
        pp_socket_print_error("fcntl()");
        return -1;
    }
    if (fcntl(fd, F_SETFL, *original_flags | O_NONBLOCK) < 0) {
        pp_socket_print_error("fcntl()");
        return -1;
    }
    return 0;
}

static int pp_socket_restore_blocking(os_socket_fd fd, int original_flags) {
    if (fcntl(fd, F_SETFL, original_flags) < 0) {
        pp_socket_print_error("fcntl()");
        return -1;
    }
    return 0;
}
#endif

static bool pp_socket_parse_numeric_addr(const char *ip_addr,
                                         uint16_t port,
                                         struct sockaddr_storage *addr,
                                         socklen_t *addrlen) {
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

static void pp_socket_close_impl(pp_socket sock) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
        return;
    }
    pp_socket_close_fd(sock->fd);
    sock->fd = OS_INVALID_SOCKET;
}

static bool pp_socket_wait(pp_socket sock, int timeout_ms, bool want_read, bool want_write) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
        pp_socket_set_not_socket_error();
        return false;
    }

    while (true) {
        fd_set readfds;
        fd_set writefds;
        fd_set *readfds_ptr = NULL;
        fd_set *writefds_ptr = NULL;
        if (want_read) {
            FD_ZERO(&readfds);
            FD_SET(sock->fd, &readfds);
            readfds_ptr = &readfds;
        }
        if (want_write) {
            FD_ZERO(&writefds);
            FD_SET(sock->fd, &writefds);
            writefds_ptr = &writefds;
        }

        struct timeval tv;
        struct timeval *tv_ptr = NULL;
        if (timeout_ms >= 0) {
            tv.tv_sec = timeout_ms / 1000;
            tv.tv_usec = (timeout_ms % 1000) * 1000;
            tv_ptr = &tv;
        }

        const int ret = select(pp_socket_select_nfds(sock->fd), readfds_ptr, writefds_ptr, NULL, tv_ptr);
        if (ret == OS_SOCKET_ERROR) {
            if (pp_socket_is_interrupted()) {
                continue;
            }
            pp_socket_print_error("select()");
            return false;
        }
        return ret > 0;
    }
}

int pp_socket_connect_with_timeout(os_socket_fd fd,
                                   const struct sockaddr *addr,
                                   socklen_t addrlen,
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
    if (!pp_socket_is_connect_pending()) {
        pp_socket_print_error("connect()");
        return -1;
    }

    // Wait for socket to be writable
    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);

    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    // Wait until timeout
    ret = select(pp_socket_select_nfds(fd), NULL, &wfds, NULL, &tv);
    if (ret == 0) {
        pp_socket_set_timeout_error();
        return -2;  // Timeout
    } else if (ret == OS_SOCKET_ERROR) {
        pp_socket_print_error("select()");
        return -1;  // Select error
    }

    // Check SO_ERROR to see if connect succeeded
    int err = 0;
    os_socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char *)&err, &len) < 0) {
        pp_socket_print_error("getsockopt()");
        return -1;
    }
    if (err != 0) {
        pp_socket_set_error(err);
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
