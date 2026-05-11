/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

/* Opaque tun device. */
typedef struct __pp_tun_struct *pp_tun;

#if PARTOUT_ABI
#include <stdint.h>

/* Platform-specific implementations. */
int pp_tun_read(const pp_tun _Nonnull tun, uint8_t *_Nonnull dst, size_t dst_len);
int pp_tun_write(const pp_tun _Nonnull tun, const uint8_t *_Nonnull src, size_t src_len);
void pp_tun_shutdown(const pp_tun _Nonnull tun);

/* Return the file descriptor or -1 if none. */
int pp_tun_fd(const pp_tun _Nonnull tun);

/* Return the device name or NULL if none. */
const char *_Nullable pp_tun_name(const pp_tun _Nonnull tun);

/* Tunnel controller. */
void pp_tun_ctrl_test_working(void *_Nullable ref);
pp_tun _Nullable pp_tun_ctrl_set_tunnel(void *_Nullable ref,
                                        const char *_Nonnull uuid,
                                        const char *_Nullable info_json);
void pp_tun_ctrl_configure_sockets(void *_Nullable ref,
                                   const int *_Nullable fds,
                                   const size_t fds_len);
void pp_tun_ctrl_clear_tunnel(void *_Nullable ref, pp_tun _Nullable tun_impl);

/* Tunnel strategy. */
//void pp_tun_strg_prepare(void *ref);
//void pp_tun_strg_install(void *ref);
//void pp_tun_strg_uninstall(void *ref);
//void pp_tun_strg_disconnect(void *ref);
//void pp_tun_strg_send_msg(void *ref);
//void pp_tun_strg_on_active(void *ref, callback);

#endif
