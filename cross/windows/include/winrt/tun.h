// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include "socket.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void *context;
    void (*on_reachability)(void *context, bool reachable);
    void (*on_better_path)(void *context);
} winrt_tun_ctrl_delegate;
/* Delegate records are borrowed during registration; implementations copy them.
 * Contexts are borrowed until cleared. Unregistering must drain callbacks.
 * Reachability notifications are currently unimplemented. */
void winrt_tun_ctrl_set_delegate(void *controller, const winrt_tun_ctrl_delegate *delegate);
bool winrt_tun_ctrl_configure_sockets(void *controller, const winrt_socket *sockets, size_t count);
/* Starts the channel with placeholder settings; packet TUN I/O is still pending. */
bool winrt_tun_ctrl_set_tunnel(void *controller, const char *uuid, const char *info_json);
void winrt_tun_ctrl_report_snapshot(void *controller, const char *snapshot_json);
void winrt_tun_ctrl_set_environment_value(void *controller, const char *key, const char *value);
void winrt_tun_ctrl_clear_tunnel(void *controller, bool kill_switch);
void winrt_tun_ctrl_cancel_tunnel(void *controller, const char *error_message);
#ifdef __cplusplus
}
#endif
