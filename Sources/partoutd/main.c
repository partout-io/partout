/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

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

char *pp_read_file(const char *path);

int main(int argc, char *argv[]) {
    const char *profile_path = NULL;
    const char *cache_dir = NULL;
    char *profile = NULL;

    if (argc < 2) {
        puts("Configuration file required");
        return 1;
    }

    // Read input
    profile_path = argv[1];
    printf("Starting with profile at: %s\n", profile_path);
    profile = pp_read_file(profile_path);
    cache_dir = "."; // FIXME: #188, hardcoded

    // Initialize library
    partout_daemon_init_args init_args = { 0 };
    init_args.cache_dir = cache_dir;
    void *ctx = partout_init(&init_args);
    if (!ctx) {
        puts("Unable to initialize");
        goto failure;
    }

    // Start daemon
    partout_daemon_start_args start_args = { 0 };
    start_args.profile = profile;
    if (partout_daemon_start(ctx, &start_args) != 0) {
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
    if (profile) free(profile);
    return 1;
}

char *pp_read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    rewind(f);

    char *buf = malloc(size + 1);
    fread(buf, 1, size, f);
    buf[size] = '\0';

    fclose(f);
    return buf;
}
