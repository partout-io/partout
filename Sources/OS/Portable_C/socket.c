/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#define os_socket_fd SOCKET
#define OS_INVALID_SOCKET INVALID_SOCKET
#define os_close_socket closesocket
#define SOCKET_PRINT_ERROR(msg) \
    fprintf(stderr, "%s failed with error %d\n", msg, WSAGetLastError())
#else
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#define os_socket_fd int
#define OS_INVALID_SOCKET -1
#define os_close_socket close
#define SOCKET_PRINT_ERROR(msg) \
    fprintf(stderr, "%s failed: %s\n", msg, strerror(errno))
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include "portable/common.h"
#include "portable/socket.h"

int connect_with_timeout(os_socket_fd fd, const struct sockaddr *addr, socklen_t addrlen, int timeout_ms);

/* Host a file descriptor with the specific platform type. POSIX systems
 * use int, whereas Windows uses SOCKET.  */
struct _pp_socket {
    os_socket_fd fd;
};

/* Create a socket from a formerly opened file descriptor. Use uint64_t to
 * cover the whole range of possible platform values. */
pp_socket pp_socket_create(uint64_t fd) {
    pp_socket sock = pp_alloc(sizeof(pp_socket *));
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
                         int timeout) {
#ifdef _WIN32
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

    struct addrinfo hints, *resolved = NULL;
    char port_str[16] = { 0 };

    pp_zero(&hints, sizeof(hints));
    hints.ai_family = AF_UNSPEC;   // IPv4 or IPv6
    switch (proto) {
        case PPSocketProtoTCP:
            hints.ai_socktype = SOCK_STREAM;
            break;
        case PPSocketProtoUDP:
            hints.ai_socktype = SOCK_DGRAM;
            break;
    }

    snprintf(port_str, sizeof(port_str), "%u", port);
    if (getaddrinfo(ip_addr, port_str, &hints, &resolved) != 0) {
        SOCKET_PRINT_ERROR("getaddrinfo()");
        goto failure;
    }

    // Loop through resolved to find first working socket
    os_socket_fd new_fd;
    for (struct addrinfo *p = resolved; p != NULL; p = p->ai_next) {
        new_fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (new_fd == OS_INVALID_SOCKET) {
            SOCKET_PRINT_ERROR("socket()");
            continue;
        }
        const int ret = connect_with_timeout(new_fd, p->ai_addr, (int)p->ai_addrlen, timeout);
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

#ifdef _WIN32
    u_long mode = blocking ? 0 : 1;
    if (ioctlsocket(sock->fd, FIONBIO, &mode) == SOCKET_ERROR) {
        SOCKET_PRINT_ERROR("ioctlsocket()");
        goto failure;
    }
#else
    // Blocking by default
    if (!blocking) {
        const int flags = fcntl(new_fd, F_GETFL);
        if (fcntl(new_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            SOCKET_PRINT_ERROR("fnctl()");
            goto failure;
        }
    }
#endif

    // Success
    return pp_socket_create(new_fd);

failure:
    if (new_fd != OS_INVALID_SOCKET) os_close_socket(new_fd);
    return NULL;
}

/* Free the socket. */
void pp_socket_free(pp_socket sock) {
    if (!sock) return;
    os_close_socket(sock->fd);
}

/* Read up to dst_len bytes, and return the amount of the actually read
 * bytes. Returns < 0 on failure. */
int pp_socket_read(pp_socket sock, uint8_t *dst, size_t dst_len) {
    const int read_len = (int)recv(sock->fd, (void *)dst, dst_len, 0);
    if (read_len < 0) {
        /* If no messages are available at the socket, the receive call waits
         * for a message to arrive, unless the socket is nonblocking (see fcntl(2))
         * in which case the value -1 is returned and the external variable errno
         * set to EAGAIN. */
        if (errno == EAGAIN) {
            return 0;
        }
        SOCKET_PRINT_ERROR("recv()");
    }
    return read_len;
}

/* Write src_len bytes, and repeat until fully written. Returns the amount
 * of written bytes, expected to always be src_len. Returns < 0 on failure. */
int pp_socket_write(pp_socket sock, const uint8_t *src, size_t src_len) {
    size_t remaining = src_len;
    while (remaining > 0) {
        const int written_len = (int)send(sock->fd, (void *)src, src_len, 0);
        if (written_len < 0) {
            if (errno == EAGAIN) {
                return 0;
            }
            SOCKET_PRINT_ERROR("send()");
            return written_len;
        }
        remaining -= written_len;
    }
    // Expect to write all data
    pp_assert(remaining == 0);
    return (int)src_len;
}

/* Return the native file descriptor. */
uint64_t pp_socket_fd(pp_socket sock) {
    assert(sock && sock->fd != OS_INVALID_SOCKET);
    return sock->fd;
}

int connect_with_timeout(os_socket_fd fd, const struct sockaddr *addr, socklen_t addrlen, int timeout_ms) {
    int ret;

#ifdef _WIN32
    // Set non-blocking
    u_long mode = 1;
    ioctlsocket(fd, FIONBIO, &mode);
#else
    // Set non-blocking
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif

    ret = connect(fd, addr, addrlen);
    if (ret == 0) {
        // Connected immediately
        goto done;
    }

#ifdef _WIN32
    if (WSAGetLastError() != WSAEWOULDBLOCK && WSAGetLastError() != WSAEINPROGRESS) {
        return -1; // real error
    }
#else
    if (errno != EINPROGRESS) {
        return -1; // real error
    }
#endif

    // Wait for socket to be writable
    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);

    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    ret = select(fd + 1, NULL, &wfds, NULL, &tv);
    if (ret == 0) {
        return -2; // timeout
    } else if (ret < 0) {
        return -1; // select error
    }

    // Check SO_ERROR to see if connect succeeded
    int err = 0;
    socklen_t len = sizeof(err);
#ifdef _WIN32
    getsockopt(sock, SOL_SOCKET, SO_ERROR, (char*)&err, &len);
    if (err != 0) {
        WSASetLastError(err);
        return -1;
    }
#else
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
    if (err != 0) {
        errno = err;
        return -1;
    }
#endif

done:
    // Restore blocking mode
#ifdef _WIN32
    mode = 0;
    ioctlsocket(sock, FIONBIO, &mode);
#else
    fcntl(fd, F_SETFL, flags);
#endif
    return 0; // success
}
