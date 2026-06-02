/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <stdint.h>
#include "portable/common.h"
#include "portable/socket.h"

/* Opaque tun device. */
typedef struct __pp_tun_struct *pp_tun;

/* Platform-specific implementations. */
int pp_tun_read(const pp_tun _Nonnull tun, uint8_t *_Nonnull dst, size_t dst_len);
int pp_tun_write(const pp_tun _Nonnull tun, const uint8_t *_Nonnull src, size_t src_len);
void pp_tun_shutdown(const pp_tun _Nonnull tun);

/* Return the file descriptor or -1 if none. */
int pp_tun_fd(const pp_tun _Nonnull tun);

/* Return the device name or NULL if none. */
const char *_Nullable pp_tun_name(const pp_tun _Nonnull tun);

/* Tunnel controller. */
typedef struct {
    void *_Nullable ctx;
    void (*_Nonnull on_reachability)(void *_Nonnull ctx,
                                     const pp_reachability *_Nonnull reachability);
    void (*_Nonnull on_better_path)(void *_Nonnull ctx);
    char *_Nullable (*_Nonnull environment_value)(void *_Nonnull ctx, const char *_Nonnull key);
} pp_tun_ctrl_delegate;
void pp_tun_ctrl_set_delegate(void *_Nullable ref,
                              const pp_tun_ctrl_delegate *_Nullable delegate);
pp_tun _Nullable pp_tun_ctrl_set_tunnel(void *_Nullable ref,
                                        const char *_Nonnull uuid,
                                        const char *_Nullable info_json);
void pp_tun_ctrl_configure_sockets(void *_Nullable ref,
                                   const pp_reachability *_Nullable info,
                                   const int *_Nullable fds,
                                   const size_t fds_len);
void pp_tun_ctrl_report_snapshot(void *_Nullable ref,
                                 const char *_Nonnull snapshot_json);
void pp_tun_ctrl_clear_tunnel(void *_Nullable ref,
                              pp_tun _Nullable tun_impl);
void pp_tun_ctrl_cancel_tunnel(void *_Nullable ref,
                               const char *_Nullable error_message);
