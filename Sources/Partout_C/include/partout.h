/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

const char *partout_version();
void *partout_initialize(const char *cache_dir);
void partout_deinitialize(void *ctx);

// FIXME: ###, merge into partout_daemon_args as facade
typedef struct {
    void *obj;
    void (*set_address)(void *obj, const char *addr, int prefix);
    void (*include_route)(void *obj, const char *dest, const char *gw);
    void (*exclude_route)(void *obj, const char *dest);
    int (*open)(void *obj, int remote_fd); // tun_open
    void (*close)(void *obj); // tun_close
    void (*test_callback)(void *obj);
} partout_daemon_ctrl;

typedef struct {
    const char *profile;
    partout_daemon_ctrl *ctrl;
    void (*test_callback)();
} partout_daemon_args;

int partout_daemon_start(void *ctx, const partout_daemon_args *args);
void partout_daemon_stop(void *ctx);
