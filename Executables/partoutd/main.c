/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#define pp_sleep(sec) Sleep(sec * 1000)
#else
#include <unistd.h>
#define pp_sleep(sec) sleep(sec)
#endif
#include "partout.h"

int main(int argc, char *argv[]) {
    const char *profile_path = NULL;
    const char *cache_dir = NULL;
    if (argc < 2) {
        puts("Configuration file required");
        return 1;
    }

    // Read input
    profile_path = argv[1];
    printf("Starting with profile at: %s\n", profile_path);
    cache_dir = argc > 2 ? argv[2] : ".";
    printf("Caching at: %s\n", cache_dir);

    // Initialize library
    partout_init_args init_args = { 0 };
    init_args.cache_dir = cache_dir;
    void *ctx = partout_init(&init_args);
    assert(ctx);

    // Start daemon
    partout_daemon_start_args start_args = { 0 };
    start_args.profile_path = profile_path;
    if (!partout_daemon_start(ctx, &start_args)) {
        puts("Unable to start daemon");
        goto failure;
    }
    puts("Daemon successfully started");

    // Keep running
    while (1) {
        pp_sleep(10);
    }
    return 0;

failure:
    return 1;
}
