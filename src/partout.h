/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#ifndef PARTOUT_H
#define PARTOUT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

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
typedef void (*partout_logger_cb)(void *ctx, int level, const char *message);
typedef struct {
    bool logs_private_data;
    partout_logger_cb logger_fn;
    void *logger_ctx;
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
/* context_json is an optional serialized ModuleImportContext. */
char *partout_import_module(const char *text, const char *context_json);
/* Serializes a TaggedModule JSON to its native format.
 * The caller owns the returned string and must free it. */
char *partout_export_module(const char *module_json);

/* Callbacks invoked on daemon events. */
typedef struct {
    void *ctx;
    void (*set_connection_status)(void *ctx, const char *status);
    void (*set_data_count)(void *ctx, uint64_t received, uint64_t sent);
    void (*set_last_error_code)(void *ctx, const char *code);
    void (*remove)(void *ctx, const char *key);
} partout_daemon_events;

/* Existing native controller hooks. No generated models cross this interface.
 * TUN handles use the core's native representation and ownership rules; this
 * does not introduce a replacement transport API. */
typedef struct __pp_tun_struct *partout_tun;

typedef struct {
    bool reachable;
#if defined(__ANDROID__)
    int64_t network_handle;
#endif
} partout_reachability;

#if defined(_WIN32)
typedef uintptr_t partout_socket_descriptor;
#else
typedef int partout_socket_descriptor;
#endif

typedef struct {
    void *ctx;
    void (*on_reachability)(void *ctx, const partout_reachability *reachability);
    void (*on_better_path)(void *ctx);
} partout_controller_delegate;

typedef struct {
    /* NULL detaches the delegate. Stop callbacks before returning from detach. */
    void (*set_delegate)(void *controller, const partout_controller_delegate *delegate);
    /* Returns an owned native TUN handle, or NULL on failure. */
    partout_tun (*set_tunnel)(void *controller, const char *uuid, const char *info_json);
    void (*report_snapshot)(void *controller, const char *snapshot_json);
    void (*set_environment_value)(void *controller, const char *key, const char *value_json);
    void (*clear_tunnel)(void *controller, bool kill_switch);
    void (*cancel_tunnel)(void *controller, const char *error_code);
    bool (*configure_sockets)(void *controller, const partout_reachability *reachability,
                              const partout_socket_descriptor *sockets, size_t count);
} partout_controller_functions;

/* Bindings to externally executed code. Rebuild callers with the matching ABI.
 * The core copies the bindings. Controller/context resources live until release.
 * Callback strings and arrays are borrowed for the duration of each call.
 * Callbacks must not propagate language exceptions across this boundary. */
typedef struct __partout_daemon_bindings {
    void *controller;
    /* All NULL selects the existing platform implementation. Otherwise every
     * callback is required, and controller is borrowed without reinterpretation
     * or platform-specific retention. The runtime owns it through release. */
    partout_controller_functions controller_functions;
    partout_daemon_events events;
    /* Releases the resources referenced by the struct (not
     * the struct itself). */
    void (*release)(struct __partout_daemon_bindings *);
} partout_daemon_bindings;

/* Crypto backends. */
typedef enum {
    PartoutCryptoDefault,
    PartoutCryptoOpenSSL,
    PartoutCryptoMbedTLS,
    PartoutCryptoNative
} partout_crypto;

/* Daemon feature flags (DaemonFeatureFlag bit values). */
/* Deprecated compatibility flags: the current implementations are always used. */
#define PartoutDaemonFlagExperimentalDaemon (UINT64_C(1) << 0)
#define PartoutDaemonFlagExperimentalOpenVPN (UINT64_C(1) << 1)
#define PartoutDaemonFlagExperimentalWireGuard (UINT64_C(1) << 2)

/* Daemon options. */
typedef struct {
    bool is_daemon;
    bool starts_immediately;
    bool cancels_unrecoverable;
    /* Cache root. Defaults to the system temporary directory if NULL. */
    const char *cache_dir;
    uint64_t min_data_count_delta;
    partout_crypto crypto;
    /* DaemonFeatureFlag bit mask. Zero disables all optional features. */
    uint64_t feature_flags;
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

/* Specific module ABI. */
/* Returned strings are owned by the caller and must be freed. */
char *partout_wireguard_genkey(void);
char *partout_wireguard_pubkey(const char *key);

#ifdef __cplusplus
}
#endif

#endif
