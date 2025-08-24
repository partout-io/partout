/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

/* The available protocols. */
typedef enum {
    PPSocketProtoTCP,
    PPSocketProtoUDP
} pp_socket_proto;

/* The opaque socket type. */
typedef struct _pp_socket *pp_socket;

/* Externally managed. */
pp_socket _Nonnull pp_socket_create(uint64_t fd);
void pp_socket_free(pp_socket _Nonnull sock);

/* From network connection. */
pp_socket _Nullable pp_socket_open(const char *_Nonnull ip_addr,
                                   pp_socket_proto proto,
                                   uint16_t port,
                                   bool blocking);

/* I/O */
int pp_socket_read(pp_socket _Nonnull sock,
                   uint8_t *_Nonnull dst, size_t dst_len);
int pp_socket_write(pp_socket _Nonnull sock,
                    const uint8_t *_Nonnull src, size_t src_len);

uint64_t pp_socket_fd(pp_socket _Nonnull sock);
