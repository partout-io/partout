/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "portable/common.h"

#pragma clang assume_nonnull begin

/* Network reachability. */
typedef struct {
    bool reachable;
#if PARTOUT_ANDROID
    uint64_t network_handle;
#endif
} pp_reachability;

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

/* Create a socket wrapper from an already open native descriptor. */
pp_socket pp_socket_retain(pp_fd fd);
static inline void pp_socket_release(pp_socket sock) {
    pp_socket_free_and_close(sock, false);
}

/* Create socket to endpoint. */
pp_socket _Nullable pp_socket_open(const char *ip_addr,
                                   pp_socket_proto proto,
                                   uint16_t port,
                                   bool blocking,
                                   int timeout_ms,
                                   const pp_reachability *_Nullable info,
                                   bool (*_Nullable configure)(void *_Nullable ctx, pp_fd fd),
                                   void *_Nullable configure_ctx);

/* I/O. Returns PPIOErrorWouldBlock when a non-blocking operation would block. */
int pp_socket_read(pp_socket sock,
                   uint8_t *dst, size_t dst_len);
int pp_socket_write(pp_socket sock,
                    const uint8_t *src, size_t src_len);
bool pp_socket_set_buffers(pp_socket sock,
                           int recvbuf_len,
                           int sendbuf_len);

/* Universal file descriptor. */
pp_fd pp_socket_get_fd(pp_socket sock);

#pragma clang assume_nonnull end
