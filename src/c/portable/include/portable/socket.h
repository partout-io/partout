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

/* Create a nonblocking connected socket, or bind unconnected UDP to a numeric local endpoint
 * Unconnected IPv6 is IPv6-only unless dual_stack is enabled; configuration runs before bind.
 * Dual-stack wildcard binds fall back to IPv4 when IPv6 is unsupported.
 * timeout_ms applies only to connected sockets. */
typedef bool (*pp_socket_configure)(void *_Nullable ctx,
                                    pp_socket_fd fd,
                                    const pp_reachability *_Nullable reachability);

typedef struct {
    bool unconnected;
    bool dual_stack; /* Only for unconnected IPv6 UDP; accepts IPv4-mapped traffic. */
    int timeout_ms;
    const pp_reachability *_Nullable reachability;
    pp_socket_configure _Nullable configure;
    void *_Nullable configure_ctx;
} pp_socket_open_options;

pp_socket _Nullable pp_socket_open(const char *hostname,
                                   pp_socket_proto proto,
                                   uint16_t port,
                                   const pp_socket_open_options *options);

/* Numeric UDP endpoint. family is 4 or 6; port and scope_id are host endian. */
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} pp_socket_address;

/* I/O. Returns PPIOErrorWouldBlock when a non-blocking operation would block.
 * Unconnected UDP writes require destination; reads require source.
 * Dual-stack sockets expose IPv4 peers as family 4, without mapped IPv6 addresses.
 * Connected sockets ignore destination and clear source if supplied. */
int pp_socket_read(pp_socket sock,
                   uint8_t *dst, size_t dst_len, pp_socket_address *_Nullable source);
int pp_socket_write(pp_socket sock,
                    const uint8_t *src, size_t src_len,
                    const pp_socket_address *_Nullable destination);
bool pp_socket_set_buffers(pp_socket sock,
                           int recvbuf_len,
                           int sendbuf_len);

bool pp_socket_get_address(pp_socket sock, pp_socket_address *address);
/* Returns the actual peer selected by connect(), including after DNS resolution. */
bool pp_socket_get_peer_address(pp_socket sock, pp_socket_address *address);

/* Native socket descriptor. */
pp_socket_fd pp_socket_get_fd(pp_socket sock);

/* Return the file descriptor to watch. Check result with pp_fd_is_valid(). */
pp_fd pp_socket_get_watch_fd(pp_socket sock);

/* Configure nonblocking I/O for the native socket. */
int pp_socket_set_nonblocking(pp_socket_fd fd);

/* Configure and reset the socket events associated with the watch fd. */
bool pp_socket_set_event_mask(pp_socket sock, bool read, bool write);
bool pp_socket_reset_events(pp_socket sock);

int pp_socket_last_error_binding(void);

#pragma clang assume_nonnull end
