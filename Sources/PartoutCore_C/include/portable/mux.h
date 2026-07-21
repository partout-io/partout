/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "conditionals.h"

#include <stdbool.h>
#include "portable/socket.h"

#pragma clang assume_nonnull begin

typedef struct __pp_mux *pp_mux;

extern const int PPMuxErrorNull;

pp_mux _Nullable pp_mux_create(int num);
void pp_mux_free(pp_mux mux);

bool pp_mux_add(pp_mux mux, pp_fd fd);
bool pp_mux_delete(pp_mux mux, pp_fd fd);
bool pp_mux_set_read(pp_mux mux, pp_fd fd, bool enable);
bool pp_mux_set_write(pp_mux mux, pp_fd fd, bool enable);
void pp_mux_set_on_readable(pp_mux mux, void (*callback)(void *ctx, pp_fd fd), void *ctx);
void pp_mux_set_on_writable(pp_mux mux, void (*callback)(void *ctx, pp_fd fd), void *ctx);
/*
 * Waits until an enabled descriptor is ready, the mux is explicitly woken,
 * or the timeout expires. Negative timeouts wait indefinitely, zero polls
 * without blocking, and positive values are expressed in milliseconds.
 * Returns zero on timeout, a positive value on an event, and a negative value
 * on error.
 */
int pp_mux_wait_timeout(pp_mux mux, int *_Nullable error_code, int timeout_ms);
int pp_mux_wait(pp_mux mux, int *_Nullable error_code);
bool pp_mux_wake(pp_mux mux);

#pragma clang assume_nonnull end
