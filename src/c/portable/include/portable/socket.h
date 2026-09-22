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
#include "portable/common.h"
#include "portable/dns.h"

#pragma clang assume_nonnull begin

/* The available protocols. */
typedef enum {
    PPSocketProtoTCP,
    PPSocketProtoUDP
} pp_socket_proto;

/* The opaque socket type. */
typedef struct __pp_socket_struct *pp_socket;

/* Close the owned socket and free the wrapper. */
void pp_socket_free(pp_socket sock);

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

int pp_socket_last_error_binding(void);

#pragma clang assume_nonnull end
