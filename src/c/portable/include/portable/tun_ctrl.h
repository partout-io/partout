/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "portable/dns.h"
#include "portable/tun.h"

#pragma clang assume_nonnull begin

/* Tunnel controller. */
typedef struct {
    void *_Nullable ctx;
    void (*on_reachability)(void *_Nullable ctx, const pp_reachability *reachability);
    void (*on_better_path)(void *_Nullable ctx);
} pp_tun_ctrl_delegate;

typedef struct {
    void (*set_delegate)(void *_Nullable ref,
                         const pp_tun_ctrl_delegate *_Nullable delegate);
    bool (*configure_sockets)(void *_Nullable ref,
                              const pp_reachability *_Nullable info,
                              const pp_socket_fd *_Nonnull fds,
                              size_t fds_len);
    pp_tun _Nullable (*_Nonnull set_tunnel)(void *_Nullable ref,
                                            const char *uuid,
                                            const char *_Nullable info_json);
    void (*report_snapshot)(void *_Nullable ref,
                            const char *snapshot_json);
    void (*set_environment_value)(void *_Nullable ref,
                                  const char *key,
                                  const char *_Nullable value);
    void (*clear_tunnel)(void *_Nullable ref, bool kill_switch);
    void (*cancel_tunnel)(void *_Nullable ref,
                          const char *_Nullable error_code);
} pp_tun_ctrl_fnt;

/* Return the function table for the current platform. */
pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void);

#pragma clang assume_nonnull end
