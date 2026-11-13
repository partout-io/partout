// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include "runtime.h"
#include <stdio.h>

// Only Android OS services and the tunnel wrapper are substituted. The test
// links the production controller.c and jni.c and calls their function table.
int __android_log_print(int priority, const char *tag, const char *format, ...) {
    (void)priority;
    (void)tag;
    (void)format;
    return 0;
}

int android_setsocknetwork(uint64_t network, int fd) {
    (void)network;
    (void)fd;
    abort();
}

static int borrowed_fd = -1;
static bool borrowed_owned = true;
static char tunnel_token;

partout_tun partout_tun_wrap_fd(int fd, bool owned) {
    borrowed_fd = fd;
    borrowed_owned = owned;
    return (partout_tun)&tunnel_token;
}

JNIEXPORT jboolean JNICALL
Java_io_partout_ControllerBindingsTest_exercise(JNIEnv *env, jclass cls, jobject controller) {
    (void)cls;
    partout_controller_functions functions = partout_android_controller_functions();
    partout_controller_delegate delegate = {0};
    functions.set_delegate(controller, &delegate);
    functions.set_delegate(controller, &delegate);
    functions.set_delegate(controller, NULL);
    partout_tun tunnel = functions.set_tunnel(controller, "test", "{\"test\":true}");
    if ((*env)->ExceptionCheck(env)) return JNI_FALSE;
    if (tunnel != (partout_tun)&tunnel_token || borrowed_fd != 42 || borrowed_owned) return JNI_FALSE;
    const partout_socket_descriptor sockets[] = {7, 11};
    if (!functions.configure_sockets(controller, NULL, sockets, 2)) return JNI_FALSE;
    functions.report_snapshot(controller, "{\"connected\":true}");
    functions.set_environment_value(controller, "key", "value");
    functions.set_environment_value(controller, "key", NULL);
    functions.clear_tunnel(controller, true);
    functions.clear_tunnel(controller, false);
    functions.cancel_tunnel(controller, "error");
    functions.cancel_tunnel(controller, NULL);
    return (*env)->ExceptionCheck(env) ? JNI_FALSE : JNI_TRUE;
}
