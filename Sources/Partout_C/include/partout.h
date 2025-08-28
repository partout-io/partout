/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

const char *partout_version();

void *partout_initialize(const char *cache_dir);
int partout_daemon_start(void *ctx, const char *profile);
void partout_daemon_stop(void *ctx);
