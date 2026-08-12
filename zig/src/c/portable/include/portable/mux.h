/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

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
int pp_mux_wait(pp_mux mux, int *_Nullable error_code);
bool pp_mux_wake(pp_mux mux);

#pragma clang assume_nonnull end
