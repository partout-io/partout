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

/* Returns the library version. The returned string must not be freed. */
const char *partout_version(void);

/* Logging configuration. */
typedef enum {
    PartoutLogLevelFault = 0,
    PartoutLogLevelError,
    PartoutLogLevelNotice,
    PartoutLogLevelInfo,
    PartoutLogLevelDebug
} partout_log_level;
/* The message is borrowed for the duration of the callback. */
typedef void (*partout_logger_cb)(void *ctx, int level, const char *message);
typedef struct {
    bool logs_private_data;
    partout_logger_cb logger_fn;
    void *logger_ctx;
} partout_init_args;
/* Configures process-wide logging. Keep logger_ctx alive while registered. */
void partout_init(const partout_init_args *args);
/* Set the maximum accepted severity after init (default: Debug). Invalid values are ignored. */
void partout_set_log_level(int level);

/* File utilities. */
char *partout_readfile(const char *rel_path, const char *parent);

/* Daemon startup result codes. */
typedef enum {
    PartoutCompletionCodeOK         = 0,
    PartoutCompletionCodeMemory     = -3,
    PartoutCompletionCodeArgs       = -2,
    PartoutCompletionCodeFailure    = -1
} partout_completion_code;

/* Import functions return an ABIEnvelope JSON string containing a result or error.
 * The caller must free the returned string. NULL means no result was produced. */
/* Imports a profile with an optional name. */
char *partout_import_profile(const char *text, const char *name);
/* Imports a module. context_json is an optional ModuleImportContext JSON string. */
char *partout_import_module(const char *text, const char *context_json);
/* Serializes TaggedModule JSON to its native format, or returns NULL on failure.
 * The caller must free the returned string. */
char *partout_export_module(const char *module_json);

/* Optional daemon event callbacks. */
typedef struct {
    void *ctx;
    void (*set_connection_status)(void *ctx, const char *status);
    void (*set_data_count)(void *ctx, uint64_t received, uint64_t sent);
    void (*set_last_error_code)(void *ctx, const char *code);
    void (*remove)(void *ctx, const char *key);
} partout_daemon_events;

/* Opaque TUN handle. */
typedef struct __partout_tun_struct *partout_tun;

/* Wraps a native TUN descriptor, or returns NULL on failure.
 * If owned, the core takes ownership on success and closes it on release.
 * Otherwise, the caller must keep the descriptor open until TUN release.
 * Failure leaves the descriptor with the caller. */
partout_tun partout_tun_wrap_fd(int fd, bool owned);

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
    /* Copy the delegate if needed after this call. NULL detaches it; stop and
     * drain delegate callbacks before returning from detach. */
    void (*set_delegate)(void *controller, const partout_controller_delegate *delegate);
    /* Transfers the returned TUN handle to the core, or returns NULL on failure. */
    partout_tun (*set_tunnel)(void *controller, const char *uuid, const char *info_json);
    void (*report_snapshot)(void *controller, const char *snapshot_json);
    void (*set_environment_value)(void *controller, const char *key, const char *value_json);
    void (*clear_tunnel)(void *controller, bool kill_switch);
    void (*cancel_tunnel)(void *controller, const char *error_code);
    bool (*configure_sockets)(void *controller, const partout_reachability *reachability,
                              const partout_socket_descriptor *sockets, size_t count);
} partout_controller_functions;

/* Runtime callbacks and context. The core copies the bindings.
 * The runtime must keep controller/context resources alive until release.
 * Callback strings and arrays are borrowed for the duration of each call.
 * Callbacks must not propagate language exceptions across this boundary. */
typedef struct __partout_daemon_bindings {
    void *controller;
    /* All controller callbacks are required. */
    partout_controller_functions controller_functions;
    partout_daemon_events events;
    /* Optional cleanup, called on startup failure or daemon destruction.
     * Releases referenced resources, not this struct. */
    void (*release)(struct __partout_daemon_bindings *);
} partout_daemon_bindings;

/* Crypto backends. */
typedef enum {
    PartoutCryptoDefault,
    PartoutCryptoOpenSSL,
    PartoutCryptoMbedTLS,
    PartoutCryptoNative
} partout_crypto;

/* Deprecated DaemonFeatureFlag values, accepted for compatibility but ignored. */
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
    /* DaemonFeatureFlag bit mask. Use zero; unknown bits are rejected. */
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

/* WireGuard keys are base64-encoded. Returns NULL on failure or if WireGuard
 * is unavailable. The caller must free returned strings. */
char *partout_wireguard_genkey(void);
char *partout_wireguard_pubkey(const char *key);

#ifdef __cplusplus
}
#endif

#endif
