/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include "portable/common.h"
#include "portable/socket.h"

/* Redefine these manually because the <sys/kern_control.h>
 * header is not exposed to iOS/tvOS */
#if PARTOUT_APPLE && !PARTOUT_MACOS
struct ctl_info {
    u_int32_t   ctl_id;
    char        ctl_name[96];
};
struct sockaddr_ctl {
    u_char      sc_len;
    u_char      sc_family;
    u_int16_t   ss_sysaddr;
    u_int32_t   sc_id;
    u_int32_t   sc_unit;
    u_int32_t   sc_reserved[5];
};
#endif

#pragma clang assume_nonnull begin

/* Opaque tun device. */
typedef struct __pp_tun_struct *pp_tun;

extern const int PPTunErrorWouldBlock;
extern const int PPTunErrorNoBuf;

#if !PARTOUT_WINDOWS
/* With manual file descriptor. */
pp_tun pp_tun_create(int fd);

static inline int pp_tun_handle_result(int ret) {
    if (ret < 0) {
        if (PP_IO_WOULD_BLOCK()) {
            return PPTunErrorWouldBlock;
        }
        if (PP_IO_NOBUFS()) {
            return PPTunErrorNoBuf;
        }
    }
    return ret;
}
#endif

/* Platform-specific implementations. */
pp_tun _Nullable pp_tun_open(const char *uuid);
int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len);
int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len);
void pp_tun_shutdown(const pp_tun tun);
void pp_tun_free_and_close(pp_tun tun, bool and_close);

static inline void pp_tun_release(pp_tun tun) {
    pp_tun_free_and_close(tun, false);
}
static inline void pp_tun_free(pp_tun tun) {
    pp_tun_free_and_close(tun, true);
}

/* Return the file descriptor or -1 if none. */
int pp_tun_fd(const pp_tun tun);

/* Return the device name or NULL if none. */
const char *_Nullable pp_tun_name(const pp_tun tun);

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
                                   const int *_Nullable fds,
                                   const size_t fds_len);
void pp_tun_ctrl_report_snapshot(void *_Nullable ref,
                                 const char *snapshot_json);
void pp_tun_ctrl_clear_tunnel(void *_Nullable ref, bool kill_switch);
void pp_tun_ctrl_cancel_tunnel(void *_Nullable ref,
                               const char *_Nullable error_message);

#pragma clang assume_nonnull end
