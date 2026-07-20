/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#ifndef PARTOUT_H
#define PARTOUT_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Current library version. */
const char *partout_version(void);

/* Library initializiation, call it ASAP. */
typedef enum {
    PartoutLogLevelFault = 0,
    PartoutLogLevelError,
    PartoutLogLevelNotice,
    PartoutLogLevelInfo,
    PartoutLogLevelDebug
} partout_log_level;
typedef void (*partout_logger_cb)(int level, const char *message);
typedef struct {
    bool logs_private_data;
    partout_logger_cb logger;
} partout_init_args;
void partout_init(const partout_init_args *args);

/* Common functions. */
char *partout_readfile(const char *rel_path, const char *parent);

/* ABI result codes. */
typedef enum {
    PartoutCompletionCodeOK         = 0,
    PartoutCompletionCodeMemory     = -3,
    PartoutCompletionCodeArgs       = -2,
    PartoutCompletionCodeFailure    = -1
} partout_completion_code;

/* Import profiles. */
char *partout_import_profile(const char *text, const char *name);
char *partout_import_module(const char *text);

/* Callbacks invoked on daemon events. */
typedef struct {
    void *ctx;
    void (*set_connection_status)(void *ctx, const char *status);
    void (*set_data_count)(void *ctx, uint64_t received, uint64_t sent);
    void (*set_last_error_code)(void *ctx, const char *code);
    void (*remove)(void *ctx, const char *key);
} partout_daemon_events;

/* Bindings to externally executed code. */
typedef struct __partout_daemon_bindings {
    void *controller;
    partout_daemon_events events;
    /* Releases the resources referenced by the struct (not
     * the struct itself). */
    void (*release)(struct __partout_daemon_bindings *);
} partout_daemon_bindings;

/* Daemon options. */
typedef struct {
    bool is_daemon;
    bool starts_immediately;
    /* Defaults to the system temporary directory if NULL. */
    const char *cache_dir;
    uint64_t min_data_count_delta;
} partout_daemon_options;

/* Daemon initialization. */
typedef struct {
    const char *profile;
    partout_daemon_options options;
    const partout_daemon_bindings *bindings;
} partout_daemon_start_args;

/* Daemon functions. */
int partout_daemon_start(const partout_daemon_start_args *args);
void partout_daemon_hold(void);
void partout_daemon_stop(void);

#ifdef __cplusplus
}
#endif

#endif
