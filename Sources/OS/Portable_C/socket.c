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
 * the non-blocking flag as an option. */
pp_socket pp_socket_open(const char *ip_addr,
                         pp_socket_proto proto,
                         uint16_t port,
                         bool blocking) {
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

    pp_socket sock = NULL;
    struct addrinfo hints, *res = NULL;
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%u", port);

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

    // FIXME: ###, getaddrinfo() is blocking!
    if (getaddrinfo(ip_addr, port_str, &hints, &res) != 0) {
        SOCKET_PRINT_ERROR("getaddrinfo()");
        goto failure;
    }

    sock = pp_alloc(sizeof(struct _pp_socket));
    sock->fd = OS_INVALID_SOCKET;

    struct addrinfo *p;
    for (p = res; p != NULL; p = p->ai_next) {
        sock->fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (sock->fd == OS_INVALID_SOCKET) {
            SOCKET_PRINT_ERROR("socket()");
            goto failed_socket;
        }

        // FIXME: ###, connect() is blocking!
//        // Make non-blocking?
//        const int flags = fcntl(fd, F_GETFL);
//        if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) goto failed_socket;

        if (connect(sock->fd, p->ai_addr, (int)p->ai_addrlen) == 0) {
            break; // Success
        }
        SOCKET_PRINT_ERROR("connect()");

    failed_socket:
        if (sock->fd != OS_INVALID_SOCKET) os_close_socket(sock->fd);
        sock->fd = OS_INVALID_SOCKET;
    }
    freeaddrinfo(res);

    // No socket in the for loop managed to connect()
    if (sock->fd == OS_INVALID_SOCKET) {
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
        const int flags = fcntl(sock->fd, F_GETFL);
        if (fcntl(sock->fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            SOCKET_PRINT_ERROR("fnctl()");
            goto failed_socket;
        }
    }
#endif

    /* Best-effort to avoid port reuse. */
    struct sockaddr_in local = { 0 };
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = 0;
    bind(sock->fd, (struct sockaddr *)&local, sizeof(local));

    return sock;

failure:
    if (sock) {
        if (sock->fd != OS_INVALID_SOCKET) {
            os_close_socket(sock->fd);
        }
        pp_free(sock);
    }
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
