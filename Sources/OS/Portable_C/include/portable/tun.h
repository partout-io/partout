/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

/* Only available on macOS and Linux. */
#if TARGET_OS_OSX || defined(__linux)

#include <unistd.h>
#include "portable/socket.h"

/* A tun device has a device name, and an associated socket to
 * do I/O. Usually a regular POSIX file descriptor. */
struct _pp_tun {
    const char *_Nonnull dev_name;
    pp_socket _Nonnull sock;
};

/* Opaque tun device. */
typedef struct _pp_tun *pp_tun;

/* Lifetime. */
pp_tun _Nullable pp_tun_create(const char *_Nonnull name, uint64_t fd);
void pp_tun_free(pp_tun _Nonnull tun);

/* Return the device name. */
static inline
const char *_Nonnull pp_tun_name(pp_tun _Nonnull tun) {
    return tun->dev_name;
}

/* Return the socket associated to the tun device. */
static inline
const pp_socket _Nonnull pp_tun_socket(pp_tun _Nonnull tun) {
    return tun->sock;
}

static inline
ssize_t pp_tun_raw_read(const pp_tun _Nonnull tun, uint8_t *_Nonnull dst, size_t dst_len) {
    const int fd = (int)pp_socket_fd(pp_tun_socket(tun));
    return read(fd, dst, dst_len);
}

static inline
ssize_t pp_tun_raw_write(const pp_tun _Nonnull tun, const uint8_t *_Nonnull src, size_t src_len) {
    const int fd = (int)pp_socket_fd(pp_tun_socket(tun));
    return write(fd, src, src_len);
}

/* Platform-specific implementations. */
pp_tun _Nullable pp_tun_open();
ssize_t pp_tun_read(const pp_tun _Nonnull tun, uint8_t *_Nonnull dst, size_t dst_len);
ssize_t pp_tun_write(const pp_tun _Nonnull tun, const uint8_t *_Nonnull src, size_t src_len);

#endif
