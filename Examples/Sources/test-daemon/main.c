// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <stdio.h>
#include <stdbool.h>
#include "partout.h"

int main(int argc, const char *argv[]) {
    partout_init_args init_args = { 0 };
    init_args.log_tag = "test-daemon";
    partout_init(&init_args);
    puts(partout_version());
    if (argc < 2) {
        fprintf(stderr, "Missing profile\n");
        return -1;
    }
    const char *parent = NULL;
    if (getenv("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != NULL) {
        parent = "PartoutExamples_test-daemon.bundle/Contents/Resources/profiles";
    }
    const char *profile_filename = argv[1];
    char *profile = partout_readfile(profile_filename, parent);
    if (!profile) {
        fprintf(stderr, "Unable to read profile\n");
        return -1;
    }
    partout_daemon_start_args args = { 0 };
    args.profile = profile;
    args.is_daemon = true;
    args.cache_dir = ".";
    args.bindings = NULL;
    const partout_completion_code result = partout_daemon_start(&args);
    free(profile);
    if (result != PartoutCompletionCodeOK) {
        fprintf(stderr, "Unable to start daemon: %d\n", result);
        return -1;
    }
    return 0;
}
