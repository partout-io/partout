/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "portable/tunctrl.h"

#ifdef __ANDROID__

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
static const kotlin_sig sig_build = {
    "build",
    "(Ljava/lang/String;)I"
};
static const kotlin_sig sig_configureSockets = {
    "configureSockets",
    "([I)V"
};
static const kotlin_sig sig_close = {
    "close",
    "()V"
};

// This must match Partout pp_tun tun_android.c
typedef struct {
    int fd;
} vpn_impl;

void pp_tun_ctrl_test_working_wrapper(void *jni_ref) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "test_working_wrapper(%p)", jni_ref);

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return;

    jclass cls = (*env)->GetObjectClass(env, jni_ref);
    jmethodID testWorkingMethod = (*env)->GetMethodID(
        env, cls, sig_testWorking.name, sig_testWorking.signature
    );
    (*env)->CallVoidMethod(env, jni_ref, testWorkingMethod);
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
}

void *pp_tun_ctrl_set_tunnel(void *jni_ref, const char *info_json) {
    assert(jni_ref);
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "set_tunnel()");

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return NULL;

    void *result = NULL;
    jclass cls = NULL;
    jstring infoJson = NULL;
    vpn_impl *impl = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "set_tunnel(): GetObjectClass returned NULL");
        goto cleanup;
    }

    infoJson = info_json ? (*env)->NewStringUTF(env, info_json) : NULL;
    jmethodID buildMethod = (*env)->GetMethodID(env, cls, sig_build.name, sig_build.signature);
    if (buildMethod == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "set_tunnel(): build() method not found");
        goto cleanup;
    }

    const jint fd = (*env)->CallIntMethod(env, jni_ref, buildMethod, infoJson);
    if (fd < 0) {
        goto cleanup;
    }

    impl = malloc(sizeof(*impl));
    if (impl == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "set_tunnel(): malloc failed");
        goto cleanup;
    }
    impl->fd = fd;
    result = impl;

cleanup:
    if (infoJson != NULL) {
        (*env)->DeleteLocalRef(env, infoJson);
    }
    if (cls != NULL) {
        (*env)->DeleteLocalRef(env, cls);
    }
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);

    return result;
}

void pp_tun_ctrl_configure_sockets(void *jni_ref, const int *fds, const size_t fds_len) {
    assert(jni_ref && fds && fds_len > 0);
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "configure_sockets()");

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return;

    jintArray fdsObj = NULL;
    jclass cls = NULL;
    jmethodID cfgMethod = NULL;

    fdsObj = (*env)->NewIntArray(env, (jsize)fds_len);
    if (fdsObj == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "configure_sockets(): failed to allocate int[]");
        goto cleanup;
    }
    (*env)->SetIntArrayRegion(env, fdsObj, 0, (jsize)fds_len, (const jint *)fds);

    // Call wrapper.configureSockets()
    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "configure_sockets(): GetObjectClass returned NULL");
        goto cleanup;
    }

    cfgMethod = (*env)->GetMethodID(env, cls, sig_configureSockets.name, sig_configureSockets.signature);
    if (cfgMethod == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "configure_sockets(): configureSockets method not found");
        goto cleanup;
    }

    (*env)->CallVoidMethod(env, jni_ref, cfgMethod, fdsObj);

cleanup:
    if (fdsObj != NULL) {
        (*env)->DeleteLocalRef(env, fdsObj);
    }
    if (cls != NULL) {
        (*env)->DeleteLocalRef(env, cls);
    }
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
}

void pp_tun_ctrl_clear_tunnel(void *jni_ref, void *tun_impl) {
    assert(jni_ref && tun_impl);
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "clear_tunnel()");

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return;

    // Release the tun_impl allocated in set_tunnel
    vpn_impl *impl = tun_impl;
    // Do not close impl->fd, wrapper.close() will take care
    free(impl);

    // Call wrapper.close()
    jclass cls = (*env)->GetObjectClass(env, jni_ref);
    jmethodID closeMethod = (*env)->GetMethodID(env, cls, sig_close.name, sig_close.signature);
    (*env)->CallVoidMethod(env, jni_ref, closeMethod);
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
}

void pp_tun_ctrl_free(void *jni_ref) {
    assert(jni_ref);

    bool did_attach;
    JNIEnv *env = pp_jni_attach_thread(&did_attach);
    if (!env) return;

    (*env)->DeleteGlobalRef(env, jni_ref);
    if (did_attach) (*jvm)->DetachCurrentThread(jvm);
}

#else

void pp_tun_ctrl_test_working_wrapper(void *ref) {
    (void)ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] test_working_wrapper(%p), ref");
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

void pp_tun_ctrl_free(void *ref) {
    (void)ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "[dummy] free(%p)", ref);
}

#endif
