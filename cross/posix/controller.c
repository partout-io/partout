// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "partout_posix.h"
static void set_delegate(void *ctx, const partout_controller_delegate *delegate) {
    (void)ctx;
    (void)delegate;
}
static partout_tun set_tunnel(void *ctx, const char *uuid, const char *json) {
    (void)ctx;
    (void)json;
    return partout_tun_open(uuid);
}
static void report_snapshot(void *ctx, const char *json) {
    (void)ctx;
    (void)json;
}
static void set_environment(void *ctx, const char *key, const char *json) {
    (void)ctx;
    (void)key;
    (void)json;
}
static void clear_tunnel(void *ctx, bool kill_switch) {
    (void)ctx;
    (void)kill_switch;
}
static void cancel_tunnel(void *ctx, const char *code) {
    (void)ctx;
    (void)code;
}
static bool configure_sockets(void *ctx, const partout_reachability *info,
                               const partout_socket_descriptor *fds, size_t count) {
    (void)ctx;
    (void)info;
    (void)fds;
    (void)count;
    return true;
}
partout_controller_functions partout_posix_controller_functions(void) {
    const partout_controller_functions functions = {
        .set_delegate = set_delegate,
        .set_tunnel = set_tunnel,
        .report_snapshot = report_snapshot,
        .set_environment_value = set_environment,
        .clear_tunnel = clear_tunnel,
        .cancel_tunnel = cancel_tunnel,
        .configure_sockets = configure_sockets
    };
    return functions;
}
