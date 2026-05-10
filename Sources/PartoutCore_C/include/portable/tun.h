/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#if PARTOUT_ABI
#include <stdint.h>

/* Opaque tun device. */
typedef struct _pp_tun *pp_tun;

/* Platform-specific implementations. */
pp_tun _Nullable pp_tun_create(const char *_Nonnull uuid, const void *_Nullable impl);
void pp_tun_free(pp_tun _Nonnull tun);
int pp_tun_read(const pp_tun _Nonnull tun, uint8_t *_Nonnull dst, size_t dst_len);
int pp_tun_write(const pp_tun _Nonnull tun, const uint8_t *_Nonnull src, size_t src_len);
void pp_tun_shutdown(const pp_tun _Nonnull tun);

/* Return the file descriptor or -1 if none. */
int pp_tun_fd(const pp_tun _Nonnull tun);

/* Return the device name or NULL if none. */
const char *_Nullable pp_tun_name(const pp_tun _Nonnull tun);

#endif
