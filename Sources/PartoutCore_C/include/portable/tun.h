/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <stdint.h>
#include "portable/common.h"

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
void pp_tun_ctrl_test_working(void *_Nullable ref);
pp_tun _Nullable pp_tun_ctrl_set_tunnel(void *_Nullable ref,
                                        const char *_Nonnull uuid,
                                        const char *_Nullable info_json);
void pp_tun_ctrl_configure_sockets(void *_Nullable ref,
                                   const int *_Nullable fds,
                                   const size_t fds_len);
void pp_tun_ctrl_clear_tunnel(void *_Nullable ref,
                              pp_tun _Nullable tun_impl);

/* Tunnel strategy. */
typedef void (*pp_tun_strg_snapshots_cb)(
    void *_Nonnull ctx,
    const char *_Nonnull snapshots_json
);
void pp_tun_strg_prepare(void *_Nullable ref,
                         void *_Nonnull ctx,
                         _Nonnull pp_tun_strg_snapshots_cb snapshots_cb);
void pp_tun_strg_install(void *_Nullable ref,
                         const char *_Nonnull profile_json,
                         bool connect,
                         const char *_Nullable options_json,
                         void *_Nullable ctx,
                         _Nullable pp_completion completion);
void pp_tun_strg_uninstall(void *_Nullable ref,
                           const char *_Nonnull profile_id,
                           void *_Nullable ctx,
                           _Nullable pp_completion completion);
void pp_tun_strg_disconnect(void *_Nullable ref,
                            const char *_Nonnull profile_id,
                            void *_Nullable ctx,
                            _Nullable pp_completion completion);

//void pp_tun_strg_prepare(void *ref);
//void pp_tun_strg_send_msg(void *ref);
//void pp_tun_strg_on_active(void *ref, callback);
