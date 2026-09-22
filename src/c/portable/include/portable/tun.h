/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "conditionals.h"

#include <stdbool.h>
#include <stdint.h>
#include "portable/common.h"

#pragma clang assume_nonnull begin

/* Opaque tun device. */
typedef struct __pp_tun_struct *pp_tun;

#if !PARTOUT_WINDOWS

#if PARTOUT_MACOS || PARTOUT_LINUX
/* Request a new device. */
pp_tun _Nullable pp_tun_open(const char *uuid);
#endif

#if PARTOUT_APPLE
/* Look up Network Extension fd. */
pp_tun _Nullable pp_tun_lookup(void);
pp_fd pp_tun_network_extension_fd(void);
#endif

/* Platform-specific implementations. */
int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len);
int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len);
void pp_tun_close(const pp_tun tun);
void pp_tun_free_and_close(pp_tun tun, bool and_close);

static inline void pp_tun_free(pp_tun tun) {
    pp_tun_free_and_close(tun, true);
}

/* Return the file descriptor. Check result with pp_fd_is_valid(). */
pp_fd pp_tun_get_watch_fd(const pp_tun tun);

/* Return the device name or NULL if none. */
const char *_Nullable pp_tun_name(const pp_tun tun);

#endif

#pragma clang assume_nonnull end
