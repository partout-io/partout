/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tun.h"

#if PARTOUT_ANDROID

#include <jni.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* Expect this struct from pp_tun_ctrl_set_tunnel(). */
struct _pp_tun {
    int fd;
};

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    if (!tun || tun->fd < 0) return -1;
    return read(tun->fd, dst, dst_len);
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    if (!tun || tun->fd < 0) return -1;
    return write(tun->fd, src, src_len);
}

void pp_tun_shutdown(const pp_tun tun) {
    if (!tun || tun->fd < 0) return;
    close(tun->fd);
    tun->fd = -1;
}

int pp_tun_fd(const pp_tun tun) {
    if (!tun) return -1;
    return tun->fd;
}

const char *pp_tun_name(const pp_tun tun) {
    (void)tun;
    return NULL;
}

/* Kotlin signatures for AndroidTunnelController. */
typedef struct {
    const char *name;
    const char *signature;
} kotlin_sig;

static const kotlin_sig sig_testWorking = {
    "testWorking",
    "()V"
};
static const kotlin_sig sig_setTunnelSettings = {
    "setTunnelSettings",
    "(Ljava/lang/String;)I"
};
static const kotlin_sig sig_configureSockets = {
    "configureSockets",
    "([I)V"
};
void pp_tun_ctrl_test_working(void *jni_ref) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "pp_tun_ctrl_test_working(%p)", jni_ref);

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return;

    jclass cls = NULL;
    jmethodID method = NULL;
    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_test_working(): NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_testWorking.name, sig_testWorking.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_test_working(): NULL method");
        goto cleanup;
    }
    (*env)->CallVoidMethod(env, jni_ref, method);

cleanup:
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
}

pp_tun pp_tun_ctrl_set_tunnel(void *jni_ref, const char *uuid, const char *info_json) {
    (void)uuid;
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "pp_tun_ctrl_set_tunnel(%p)", jni_ref);

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return NULL;

    jclass cls = NULL;
    jmethodID method = NULL;
    jstring j_info_json = NULL;

    // This will be the result on success
    pp_tun tun_impl = malloc(sizeof(*tun_impl));
    if (tun_impl == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_set_tunnel(): NULL tun_impl");
        goto cleanup;
    }
    tun_impl->fd = -1;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_set_tunnel(): NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_setTunnelSettings.name, sig_setTunnelSettings.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_set_tunnel(): NULL method");
        goto cleanup;
    }
    j_info_json = info_json ? (*env)->NewStringUTF(env, info_json) : NULL;
    tun_impl->fd = (*env)->CallIntMethod(env, jni_ref, method, j_info_json);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_set_tunnel(): Kotlin exception");
        tun_impl->fd = -1;
        goto cleanup;
    }
    if (tun_impl->fd < 0) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_set_tunnel(): Invalid fd");
        goto cleanup;
    }
cleanup:
    if (tun_impl != NULL && tun_impl->fd < 0) {
        free(tun_impl);
        tun_impl = NULL;
    }
    if (j_info_json != NULL) (*env)->DeleteLocalRef(env, j_info_json);
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
    return tun_impl;
}

void pp_tun_ctrl_configure_sockets(void *jni_ref, const int *fds, const size_t fds_len) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "pp_tun_ctrl_configure_sockets(%p)", jni_ref);
    if (!fds || fds_len == 0) return;

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return;

    jclass cls = NULL;
    jmethodID method = NULL;
    jintArray j_fds = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_configure_sockets(): NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_configureSockets.name, sig_configureSockets.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_configure_sockets(): NULL method");
        goto cleanup;
    }
    j_fds = (*env)->NewIntArray(env, (jsize)fds_len);
    if (j_fds == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_configure_sockets(): NULL j_fds");
        goto cleanup;
    }
    (*env)->SetIntArrayRegion(env, j_fds, 0, (jsize)fds_len, (const jint *)fds);
    (*env)->CallVoidMethod(env, jni_ref, method, j_fds);

cleanup:
    if (j_fds != NULL) (*env)->DeleteLocalRef(env, j_fds);
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
}

void pp_tun_ctrl_clear_tunnel(void *jni_ref, pp_tun tun_impl) {
    (void)jni_ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "pp_tun_ctrl_clear_tunnel(%p)", jni_ref);
    if (!tun_impl) return;
    pp_tun_shutdown(tun_impl);
    free(tun_impl);
}

#endif
