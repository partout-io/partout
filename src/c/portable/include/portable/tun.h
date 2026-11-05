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
typedef struct __partout_tun_struct *pp_tun;

#if PARTOUT_APPLE || PARTOUT_ANDROID || PARTOUT_LINUX
pp_tun _Nullable pp_tun_wrap_fd(int fd, bool owned);
#endif

#if !PARTOUT_WINDOWS
/* Platform-specific implementations. */
int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len);
int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len);

/* Return the file descriptor. Check result with pp_fd_is_valid(). */
pp_fd pp_tun_get_watch_fd(const pp_tun tun);
#endif

/* Free the wrapper and release its owned native resources. */
void pp_tun_free(pp_tun tun);

#pragma clang assume_nonnull end
