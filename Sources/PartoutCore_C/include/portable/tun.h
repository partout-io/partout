/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <stdbool.h>
#include <stdint.h>
#include "portable/common.h"
#include "portable/socket.h"

#pragma clang assume_nonnull begin

/* Opaque tun device. */
typedef struct __pp_tun_struct *pp_tun;

#if PARTOUT_MACOS || PARTOUT_LINUX || PARTOUT_WINDOWS
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

#if !PARTOUT_WINDOWS
/* Reusable with POSIX-like tun device. */
static inline int pp_tun_handle_result(int ret) {
    if (ret < 0) {
        if (pp_io_wouldblock()) {
            return PPIOErrorWouldBlock;
        }
        if (pp_io_nobufs()) {
            return PPIOErrorNoBufs;
        }
        if (pp_io_nospace()) {
            return PPIOErrorNoSpace;
        }
    }
    return ret;
}
#endif

/* Tunnel controller. */
typedef struct {
    void *_Nullable ctx;
    void (*on_reachability)(void *ctx, const pp_reachability *reachability);
    void (*on_better_path)(void *ctx);
    char *_Nullable (*_Nonnull environment_value)(void *ctx, const char *key);
} pp_tun_ctrl_delegate;
void pp_tun_ctrl_set_delegate(void *_Nullable ref,
                              const pp_tun_ctrl_delegate *_Nullable delegate);
pp_tun _Nullable pp_tun_ctrl_set_tunnel(void *_Nullable ref,
                                        const char *uuid,
                                        const char *_Nullable info_json);
bool pp_tun_ctrl_configure_sockets(void *_Nullable ref,
                                   const pp_reachability *_Nullable info,
                                   const pp_socket_fd *_Nonnull fds,
                                   const size_t fds_len);
void pp_tun_ctrl_report_snapshot(void *_Nullable ref,
                                 const char *snapshot_json,
                                 bool log);
void pp_tun_ctrl_clear_tunnel(void *_Nullable ref, bool kill_switch);
void pp_tun_ctrl_cancel_tunnel(void *_Nullable ref,
                               const char *_Nullable error_message);

#pragma clang assume_nonnull end
