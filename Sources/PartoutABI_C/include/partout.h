/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#ifndef __PARTOUT_H
#define __PARTOUT_H

#include <stdbool.h>
#include <stddef.h>

/*
 * Success -> true or != NULL
 * Failure -> false or == NULL
 */

extern const char *const PARTOUT_IDENTIFIER;
extern const char *const PARTOUT_VERSION;

const char *partout_version();
void partout_log(int level, const char *msg);

typedef struct {
    const char *cache_dir;
    void (*test_callback)();
} partout_init_args;

void *partout_init(const partout_init_args *args);
void partout_deinit(void *ctx);

typedef struct {
    const char *profile;
    const char *profile_path;
    void *ctrl_impl;
} partout_daemon_start_args;

bool partout_daemon_start(void *ctx, const partout_daemon_start_args *args);
void partout_daemon_stop(void *ctx);

#endif
