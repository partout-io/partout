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

/* A tun device has a device name, and an associated socket to
 * do I/O. Usually a regular POSIX file descriptor. */
struct _pp_tun {
    int fd;
    const char *_Nonnull dev_name;
};

/* Opaque tun device. */
typedef struct _pp_tun *pp_tun;

/* Lifetime. */
pp_tun _Nullable pp_tun_create(const char *_Nonnull name, int fd);
void pp_tun_free(pp_tun _Nonnull tun);

/* Return the file descriptor. */
static inline
int pp_tun_fd(pp_tun _Nonnull tun) {
    return tun->fd;
}

/* Return the device name. */
static inline
const char *_Nonnull pp_tun_name(pp_tun _Nonnull tun) {
    return tun->dev_name;
}

/* Platform-specific implementations. */
pp_tun _Nullable pp_tun_open();
ssize_t pp_tun_read(const pp_tun _Nonnull tun, uint8_t *_Nonnull dst, size_t dst_len);
ssize_t pp_tun_write(const pp_tun _Nonnull tun, const uint8_t *_Nonnull src, size_t src_len);

#endif
