// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "partout.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Initializes controller ownership; preserves the caller's event callbacks.
 * Pass bindings to daemon_start, which owns release even on startup failure. */
bool partout_wintun_bindings_init(partout_daemon_bindings *bindings);
/* Requires the controller context created by partout_wintun_bindings_init. */
partout_controller_functions partout_wintun_controller_functions(void);
#ifdef __cplusplus
}
#endif
