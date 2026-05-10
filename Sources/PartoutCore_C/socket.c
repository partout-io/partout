/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#if PARTOUT_WINDOWS
#include <winsock2.h>
#include <ws2tcpip.h>
#define os_socket_fd SOCKET
#define OS_INVALID_SOCKET INVALID_SOCKET
#define os_close_socket closesocket
#define os_shutdown_socket shutdown
#define OS_SHUTDOWN_BOTH SD_BOTH
#define SOCKET_PRINT_ERROR(msg) \
    pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "%s failed with error %d", msg, WSAGetLastError())
#else
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <arpa/inet.h>
#include <netdb.h>
#define os_socket_fd int
#define OS_INVALID_SOCKET -1
#define os_close_socket close
#define os_shutdown_socket shutdown
#define OS_SHUTDOWN_BOTH SHUT_RDWR
#define SOCKET_PRINT_ERROR(msg) \
    pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "%s failed: %s", msg, strerror(errno))
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include "portable/common.h"
#include "portable/socket.h"

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

#if PARTOUT_WINDOWS
    static int wsa_initialized = 0;
    if (!wsa_initialized) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            SOCKET_PRINT_ERROR("WSAStartup()");
            goto failure;
        }
        wsa_initialized = 1;
    }
#endif

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
            SOCKET_PRINT_ERROR("socket()");
            goto failure;
        }
        if (pp_socket_connect_with_timeout(new_fd,
                                           (const struct sockaddr *)&numeric_addr,
                                           numeric_addrlen,
                                           blocking,
                                           timeout_ms) != 0) {
            SOCKET_PRINT_ERROR("connect()");
            goto failure;
        }
        return pp_socket_create(new_fd);
    }

    snprintf(port_str, sizeof(port_str), "%u", port);
    if (getaddrinfo(ip_addr, port_str, &hints, &resolved) != 0) {
        SOCKET_PRINT_ERROR("getaddrinfo()");
        goto failure;
    }

    // Loop through resolved to find first working socket
    for (struct addrinfo *p = resolved; p != NULL; p = p->ai_next) {
        new_fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (new_fd == OS_INVALID_SOCKET) {
            SOCKET_PRINT_ERROR("socket()");
            continue;
        }
        const int ret = pp_socket_connect_with_timeout(new_fd,
                                                       p->ai_addr,
                                                       (int)p->ai_addrlen,
                                                       blocking,
                                                       timeout_ms);
        if (ret != 0) {
            os_close_socket(new_fd);
            SOCKET_PRINT_ERROR("connect()");
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
    if (new_fd != OS_INVALID_SOCKET) os_close_socket(new_fd);
    return NULL;
}

/* Close the native file descriptor without freeing the wrapper. */
void pp_socket_shutdown(pp_socket sock) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) return;
    (void)os_shutdown_socket(sock->fd, OS_SHUTDOWN_BOTH);
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
#if PARTOUT_WINDOWS
        WSASetLastError(WSAENOTSOCK);
#else
        errno = EBADF;
#endif
        return -1;
    }
#if PARTOUT_WINDOWS
    while (true) {
        const int read_len = (int)recv(sock->fd, (void *)dst, dst_len, 0);
        if (read_len < 0 && WSAGetLastError() == WSAEINTR) {
            continue;
        }
        if (read_len < 0) {
            if (WSAGetLastError() == WSAEWOULDBLOCK) {
                return 0;
            }
            SOCKET_PRINT_ERROR("recv()");
        }
        return read_len;
    }
#else
    while (true) {
        const int read_len = (int)read(sock->fd, (void *)dst, dst_len);
        if (read_len < 0 && errno == EINTR) {
            continue;
        }
        if (read_len < 0) {
            /* If no messages are available at the socket, the receive call waits
             * for a message to arrive, unless the socket is nonblocking (see fcntl(2))
             * in which case the value -1 is returned and the external variable errno
             * set to EAGAIN. */
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return 0;
            }
            SOCKET_PRINT_ERROR("recv()");
        }
        return read_len;
    }
#endif
}

/* Write src_len bytes, and repeat until fully written. Returns the amount
 * of written bytes, expected to always be src_len. Returns < 0 on failure. */
int pp_socket_write(pp_socket sock, const uint8_t *src, size_t src_len) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
#if PARTOUT_WINDOWS
        WSASetLastError(WSAENOTSOCK);
#else
        errno = EBADF;
#endif
        return -1;
    }

    size_t offset = 0;
    while (offset < src_len) {
        const uint8_t *current_src = src + offset;
        const size_t remaining = src_len - offset;

#if PARTOUT_WINDOWS
        const int written_len = (int)send(sock->fd, (const char *)current_src, (int)remaining, 0);
#else
        const int written_len = (int)write(sock->fd, current_src, remaining);
#endif
        if (written_len < 0) {
#if PARTOUT_WINDOWS
            const int err = WSAGetLastError();
            if (err == WSAEINTR) {
                continue;
            }
            if (err == WSAEWOULDBLOCK) {
                return offset > 0 ? (int)offset : 0;
            }
#else
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return offset > 0 ? (int)offset : 0;
            }
#endif
            SOCKET_PRINT_ERROR("send()");
            return written_len;
        }
        if (written_len == 0) {
#if PARTOUT_WINDOWS
            WSASetLastError(WSAECONNRESET);
#else
            errno = EPIPE;
#endif
            SOCKET_PRINT_ERROR("send()");
            return -1;
        }
        offset += (size_t)written_len;
    }
    return (int)offset;
}

bool pp_socket_set_buffers(pp_socket sock, int recvbuf_len, int sendbuf_len) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
#if PARTOUT_WINDOWS
        WSASetLastError(WSAENOTSOCK);
#else
        errno = EBADF;
#endif
        return false;
    }

    bool did_set = true;
    if (recvbuf_len > 0) {
        if (setsockopt(sock->fd, SOL_SOCKET, SO_RCVBUF, (const void *)&recvbuf_len, sizeof(recvbuf_len)) < 0) {
            SOCKET_PRINT_ERROR("setsockopt(SO_RCVBUF)");
            did_set = false;
        }
    }
    if (sendbuf_len > 0) {
        if (setsockopt(sock->fd, SOL_SOCKET, SO_SNDBUF, (const void *)&sendbuf_len, sizeof(sendbuf_len)) < 0) {
            SOCKET_PRINT_ERROR("setsockopt(SO_SNDBUF)");
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
    os_close_socket(sock->fd);
    sock->fd = OS_INVALID_SOCKET;
}

static bool pp_socket_wait(pp_socket sock, int timeout_ms, bool want_read, bool want_write) {
    if (!sock || sock->fd == OS_INVALID_SOCKET) {
#if PARTOUT_WINDOWS
        WSASetLastError(WSAENOTSOCK);
#else
        errno = EBADF;
#endif
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

#if PARTOUT_WINDOWS
        const int ret = select(0, readfds_ptr, writefds_ptr, NULL, tv_ptr);
        if (ret == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEINTR) {
                continue;
            }
            SOCKET_PRINT_ERROR("select()");
            return false;
        }
#else
        const int ret = select(sock->fd + 1, readfds_ptr, writefds_ptr, NULL, tv_ptr);
        if (ret < 0) {
            if (errno == EINTR) {
                continue;
            }
            SOCKET_PRINT_ERROR("select()");
            return false;
        }
#endif
        return ret > 0;
    }
}

int pp_socket_connect_with_timeout(os_socket_fd fd,
                                   const struct sockaddr *addr,
                                   socklen_t addrlen,
                                   bool blocking,
                                   int timeout_ms) {
    // Set non-blocking
#if PARTOUT_WINDOWS
    u_long mode = 1;
    if (ioctlsocket(fd, FIONBIO, &mode) == SOCKET_ERROR) {
        SOCKET_PRINT_ERROR("ioctlsocket()");
        return -1;
    }
#else
    const int original_flags = fcntl(fd, F_GETFL, 0);
    if (original_flags < 0) {
        SOCKET_PRINT_ERROR("fcntl()");
        return -1;
    }
    if (fcntl(fd, F_SETFL, original_flags | O_NONBLOCK) < 0) {
        SOCKET_PRINT_ERROR("fcntl()");
        return -1;
    }
#endif

    // At this point, this call will not block
    int ret = connect(fd, addr, addrlen);
    if (ret == 0) {
        // Connected immediately
        goto done;
    }
    // Tell real errors from non-blocking pending states
#if PARTOUT_WINDOWS
    if (WSAGetLastError() != WSAEWOULDBLOCK && WSAGetLastError() != WSAEINPROGRESS) {
        SOCKET_PRINT_ERROR("connect()");
        return -1;
    }
#else
    if (errno != EINPROGRESS) {
        SOCKET_PRINT_ERROR("connect()");
        return -1;
    }
#endif

    // Wait for socket to be writable
    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);

    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    // Wait until timeout
    ret = select(fd + 1, NULL, &wfds, NULL, &tv);
    if (ret == 0) {
#if PARTOUT_WINDOWS
        WSASetLastError(WSAETIMEDOUT);
#else
        errno = ETIMEDOUT;
#endif
        return -2;  // Timeout
    } else if (ret < 0) {
        SOCKET_PRINT_ERROR("select()");
        return -1;  // Select error
    }

    // Check SO_ERROR to see if connect succeeded
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char *)&err, &len) < 0) {
        SOCKET_PRINT_ERROR("getsockopt()");
        return -1;
    }
    if (err != 0) {
#if PARTOUT_WINDOWS
        WSASetLastError(err);
#else
        errno = err;
#endif
        return -1;
    }

done:
    // Store/restore blocking mode as needed
    if (blocking) {
#if PARTOUT_WINDOWS
        mode = 0;
        if (ioctlsocket(fd, FIONBIO, &mode) == SOCKET_ERROR) {
            SOCKET_PRINT_ERROR("ioctlsocket()");
            return -1;
        }
#else
        if (fcntl(fd, F_SETFL, original_flags) < 0) {
            SOCKET_PRINT_ERROR("fnctl()");
            return -1;
        }
#endif
    }

    // Success
    return 0;
}
