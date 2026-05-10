/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tunctrl.h"

#if PARTOUT_ANDROID

#include <jni.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

// Kotlin signatures for AndroidTunnelController
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
static const kotlin_sig sig_clearTunnelSettings = {
    "clearTunnelSettings",
    "()V"
};

// This must match Partout pp_tun tun_android.c
typedef struct {
    int fd;
} vpn_impl;

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

void *pp_tun_ctrl_set_tunnel(void *jni_ref, const char *info_json) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "pp_tun_ctrl_set_tunnel(%p)", jni_ref);

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return NULL;

    jclass cls = NULL;
    jmethodID method = NULL;
    jstring j_info_json = NULL;

    // This will be the result on success
    vpn_impl *tun_impl = malloc(sizeof(*tun_impl));
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

void pp_tun_ctrl_clear_tunnel(void *jni_ref, void *tun_impl) {
    assert(jni_ref && tun_impl);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "pp_tun_ctrl_clear_tunnel(%p)", jni_ref);

    // Release the tun_impl allocated in set_tunnel
    // Do not close impl->fd, JNI close() will take care
    free(tun_impl);

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return;

    jclass cls = NULL;
    jmethodID method = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_clear_tunnel(): NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_clearTunnelSettings.name, sig_clearTunnelSettings.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tun_ctrl_clear_tunnel(): NULL method");
        goto cleanup;
    }
    (*env)->CallVoidMethod(env, jni_ref, method);

cleanup:
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
}

#else

void pp_tun_ctrl_test_working(void *ref) {
    (void)ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] test_working(%p), ref");
}

void *pp_tun_ctrl_set_tunnel(void *ref, const char *info_json) {
    (void)ref;
    (void)info_json;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] set_tunnel(%p)", ref);
    return NULL;
}

void pp_tun_ctrl_configure_sockets(void *ref, const int *fds, const size_t fds_len) {
    (void)ref;
    (void)fds;
    (void)fds_len;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] configure_sockets(%p)", ref);
}

void pp_tun_ctrl_clear_tunnel(void *ref, void *tun_impl) {
    (void)ref;
    (void)tun_impl;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] clear_tunnel(%p)", ref);
}

#endif
