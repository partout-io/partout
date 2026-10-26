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
/* Starts the channel with negotiated settings and returns an owned TUN handle. */
typedef struct __winrt_tun_struct *winrt_tun;
typedef bool (*winrt_tun_on_receive)(void *context, const uint8_t *bytes, size_t length);
winrt_tun winrt_tun_ctrl_set_tunnel(void *controller, const char *uuid, const char *info_json);
void winrt_tun_free(winrt_tun tun);
/* Native receive callbacks are serialized and borrow input until return. Callbacks
 * consume or copy input and must not reenter TUN/controller APIs. Clearing drains
 * delivery before the borrowed context can be released. */
bool winrt_tun_set_on_receive(winrt_tun tun, winrt_tun_on_receive callback, void *context);
void winrt_tun_stop_writes(winrt_tun tun);
/* Lifecycle, writes and stop_writes are serialized by the looper; free follows
 * all outstanding ABI calls. Writes synchronously copy one IP packet into the
 * channel receive pool and append/flush it. Stopped writes return E_ABORT. */
int32_t winrt_tun_write(winrt_tun tun, const uint8_t *bytes, size_t length);
void winrt_tun_stop_writes(winrt_tun tun);
void winrt_tun_ctrl_report_snapshot(void *controller, const char *snapshot_json);
void winrt_tun_ctrl_set_environment_value(void *controller, const char *key, const char *value);
void winrt_tun_ctrl_clear_tunnel(void *controller, bool kill_switch);
void winrt_tun_ctrl_cancel_tunnel(void *controller, const char *error_message);
#ifdef __cplusplus
}
#endif
