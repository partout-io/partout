/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

/* MSVC does not support Clang's nullability annotations. */
#if defined(_MSC_VER) && !defined(__clang__)
#pragma warning(push)
#pragma warning(disable: 4068)
#define _Nullable
#define _Nonnull
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include "portable/tun.h"

/* WinRT stubs: no device is created and configuration fails. */
/* Controller ref borrows the runtime's internal PartoutTunnelController.
 * The caller must retain that context until daemon shutdown finishes. */
pp_tun pp_winrt_tun_open(const char *uuid);
int pp_winrt_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len);
int pp_winrt_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len);
void pp_winrt_tun_close(const pp_tun tun);
void pp_winrt_tun_free_and_close(pp_tun tun, bool and_close);
pp_fd pp_winrt_tun_get_watch_fd(const pp_tun tun);
const char * pp_winrt_tun_name(const pp_tun tun);
void pp_winrt_tun_ctrl_set_delegate(void *ref, const pp_tun_ctrl_delegate *delegate);
bool pp_winrt_tun_ctrl_configure_sockets(void *ref, const pp_reachability *info, const pp_socket_fd *fds, size_t fds_len);
pp_tun pp_winrt_tun_ctrl_set_tunnel(void *ref, const char *uuid, const char *info_json);
void pp_winrt_tun_ctrl_report_snapshot(void *ref, const char *snapshot_json);
void pp_winrt_tun_ctrl_set_environment_value(void *ref, const char *key, const char *value);
void pp_winrt_tun_ctrl_clear_tunnel(void *ref, bool kill_switch);
void pp_winrt_tun_ctrl_cancel_tunnel(void *ref, const char *error_message);

#ifdef __cplusplus
}
#endif

#if defined(_MSC_VER) && !defined(__clang__)
#undef _Nonnull
#undef _Nullable
#pragma warning(pop)
#endif
