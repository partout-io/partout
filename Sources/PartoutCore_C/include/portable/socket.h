/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <stdbool.h>
#include <stdint.h>

/* The available protocols. */
typedef enum {
    PPSocketProtoTCP,
    PPSocketProtoUDP
} pp_socket_proto;

/* The opaque socket type. */
typedef struct __pp_socket_struct *pp_socket;

extern const int PP_SOCKET_WOULD_BLOCK;

/* Create a socket wrapper from an already open native descriptor. The
 * wrapper acquires ownership and will close the descriptor on
 * pp_socket_close() or pp_socket_free(). */
pp_socket _Nonnull pp_socket_create(uint64_t fd);
void pp_socket_shutdown(pp_socket _Nonnull sock);
void pp_socket_close(pp_socket _Nonnull sock);
void pp_socket_free(pp_socket _Nonnull sock);

/* Create socket to endpoint. */
pp_socket _Nullable pp_socket_open(const char *_Nonnull ip_addr,
                                   pp_socket_proto proto,
                                   uint16_t port,
                                   bool blocking,
                                   int timeout_ms);

/* I/O. Returns PP_SOCKET_WOULD_BLOCK when a non-blocking operation would block. */
int pp_socket_read(pp_socket _Nonnull sock,
                   uint8_t *_Nonnull dst, size_t dst_len);
int pp_socket_write(pp_socket _Nonnull sock,
                    const uint8_t *_Nonnull src, size_t src_len);
bool pp_socket_set_buffers(pp_socket _Nonnull sock,
                           int recvbuf_len,
                           int sendbuf_len);
bool pp_socket_wait_readable(pp_socket _Nonnull sock, int timeout_ms);
bool pp_socket_wait_writable(pp_socket _Nonnull sock, int timeout_ms);

/* Universal file descriptor. */
uint64_t pp_socket_fd(pp_socket _Nonnull sock);
