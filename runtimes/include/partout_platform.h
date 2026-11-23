// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "partout.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Initializes controller ownership; preserves the caller's event callbacks.
 * Pass bindings to daemon_start, which owns release even on startup failure. */
bool partout_platform_bindings_init(partout_daemon_bindings *bindings);
#ifdef __cplusplus
}
#endif
