/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#ifndef __PARTOUT_H
#define __PARTOUT_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/* Library initializiation, call it ASAP. */
typedef struct {
    const char *log_tag;
    bool logs_private_data;
} partout_init_args;
void partout_init(const partout_init_args *args);

/* Common functions. */
const char *partout_version(void);
char *partout_readfile(const char *rel_path, const char *parent);

/* Event callback. */
typedef void (*partout_event_cb)(void *event_ctx, const char *event);

/* Completion callback.
 * - Success: code == 0, string = result
 * - Error:   code != 0, string = error (if >0, code is PartoutError.Code)
 * Both 'result' and 'error' are optional JSON payloads.
 */
#define PartoutCompletionCodeOK         0
#define PartoutCompletionCodeArgs       -2
#define PartoutCompletionCodeFailure    -1
typedef void (*partout_completion_cb)(void *ctx, int code, const char *json);
typedef struct {
    partout_completion_cb callback;
    void *ctx;
} partout_completion;

/* Macros for completion blocks. */
static inline
partout_completion PARTOUT_CB(partout_completion_cb callback, void *ctx) {
    partout_completion completion = { callback, ctx };
    return completion;
}

/* Import profiles. */
void partout_import_profile(const char *text, const char *name, partout_completion completion);

typedef struct __partout_daemon_bindings {
    void *controller;
    void (*free)(struct __partout_daemon_bindings *);
} partout_daemon_bindings;

/* Daemon options. */
typedef struct {
    bool logs_snapshots;
    uint64_t min_data_count_delta;
    const char **dns_fallback;
    size_t dns_fallback_len;
} partout_daemon_options;

/* Daemon initialization. */
typedef struct {
    const char *profile;
    const char *cache_dir;
    bool is_daemon;
    partout_daemon_options options;
    const partout_daemon_bindings *bindings;
} partout_daemon_start_args;

/* Daemon functions. */
int partout_daemon_start(const partout_daemon_start_args *args);
void partout_daemon_stop(partout_completion completion);

#endif
