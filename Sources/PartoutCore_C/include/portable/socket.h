/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "conditionals.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#if !PARTOUT_WINDOWS
#include <netdb.h>
#endif
#include "portable/common.h"

#pragma clang assume_nonnull begin

/* Network reachability. */
typedef struct {
    bool reachable;
#if PARTOUT_ANDROID
    uint64_t network_handle;
#endif
} pp_reachability;
static inline pp_reachability pp_reachability_none(void) {
#if PARTOUT_ANDROID
    static const pp_reachability none = {
        .reachable = false,
        .network_handle = 0
    };
#else
    static const pp_reachability none = {
        .reachable = false
    };
#endif
    return none;
}

#if PARTOUT_ANDROID
#include <android/multinetwork.h>
#endif

static inline int pp_dns_resolve(const char *hostname,
                                 const struct addrinfo *_Nullable hints,
                                 const pp_reachability *_Nullable reachability,
                                 struct addrinfo *_Nullable *_Nonnull infoptr) {
#if PARTOUT_ANDROID
    if (!reachability || reachability->network_handle == 0) {
        return EAI_FAIL;
    }
    return android_getaddrinfofornetwork(reachability->network_handle,
                                         hostname,
                                         NULL,
                                         hints,
                                         infoptr);
#else
    (void)reachability;
    return getaddrinfo(hostname, NULL, hints, infoptr);
#endif
}

/* The available protocols. */
typedef enum {
    PPSocketProtoTCP,
    PPSocketProtoUDP
} pp_socket_proto;

/* The opaque socket type. */
typedef struct __pp_socket_struct *pp_socket;

void pp_socket_shutdown(pp_socket sock);
void pp_socket_close(pp_socket sock);
void pp_socket_free_and_close(pp_socket sock, bool and_close);

static inline void pp_socket_free(pp_socket sock) {
    pp_socket_free_and_close(sock, true);
}

/* Create socket to endpoint. */
typedef bool (*pp_socket_configure)(void *_Nullable ctx,
                                    pp_socket_fd fd,
                                    const pp_reachability *_Nullable reachability);
pp_socket _Nullable pp_socket_open(const char *ip_addr,
                                   pp_socket_proto proto,
                                   uint16_t port,
                                   bool blocking,
                                   int timeout_ms,
                                   const pp_reachability *_Nullable reachability,
                                   pp_socket_configure _Nullable configure,
                                   void *_Nullable configure_ctx);

/* I/O. Returns PPIOErrorWouldBlock when a non-blocking operation would block. */
int pp_socket_read(pp_socket sock,
                   uint8_t *dst, size_t dst_len);
int pp_socket_write(pp_socket sock,
                    const uint8_t *src, size_t src_len);
bool pp_socket_set_buffers(pp_socket sock,
                           int recvbuf_len,
                           int sendbuf_len);

/* Native socket descriptor. */
pp_socket_fd pp_socket_get_fd(pp_socket sock);

/* Return the file descriptor to watch. Check result with pp_fd_is_valid(). */
pp_fd pp_socket_get_watch_fd(pp_socket sock);

/* These are tied to sockets on Windows. */
int pp_socket_set_nonblocking(pp_socket_fd fd, int *_Nullable original_flags);
int pp_socket_restore_blocking(pp_socket_fd fd, int original_flags);

/* Configure and reset the socket events associated with the watch fd. */
bool pp_socket_set_event_mask(pp_socket sock, bool read, bool write);
bool pp_socket_reset_events(pp_socket sock);

#if PARTOUT_WINDOWS
static inline int pp_socket_last_error(void) {
    return WSAGetLastError();
}
#else
static inline int pp_socket_last_error(void) {
    return errno;
}
#endif

#pragma clang assume_nonnull end
