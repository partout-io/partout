/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

/*
 * Success -> int == 0 or != NULL
 * Failure -> int != 0 or == NULL
 */

const char *partout_version();

typedef struct {
    const char *cache_dir;
    void (*test_callback)();
} partout_init_args;

void *partout_init(const partout_init_args *args);
void partout_deinit(void *ctx);

typedef struct {
    const char *profile;
    const char *profile_path;
} partout_daemon_start_args;

int partout_daemon_start(void *ctx, const partout_daemon_start_args *args);
void partout_daemon_stop(void *ctx);
