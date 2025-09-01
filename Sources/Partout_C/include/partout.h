/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

const char *partout_version();
void *partout_initialize(const char *cache_dir);
void partout_deinitialize(void *ctx);

typedef struct {
    const char *profile;
    void (*test_callback)();
} partout_daemon_args;

int partout_daemon_start(void *ctx, const partout_daemon_args *args);
void partout_daemon_stop(void *ctx);
