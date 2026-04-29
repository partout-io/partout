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

extern JavaVM *jvm;

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
    "(Ljava/lang/String;)Ljava/lang/Integer;"
};
static const kotlin_sig sig_configureSockets = {
    "configureSockets",
    "([Ljava/lang/Integer;)V"
};
static const kotlin_sig sig_close = {
    "close",
    "()V"
};

// This must match Partout pp_tun tun_android.c
typedef struct {
    int fd;
} vpn_impl;

JNIEnv *jni_attach_thread(bool *did_attach) {
    JNIEnv *env;
    jint status = (*jvm)->GetEnv(jvm, &env, JNI_VERSION_1_6);
    switch (status) {
        case JNI_OK:
            *did_attach = false;
            return env;
        case JNI_EDETACHED:
            status = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
            if (status != JNI_OK) {
                pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "AttachCurrentThread failed (%d)", status);
                return NULL;
            }
            *did_attach = true;
            return env;
        default:
            pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "GetEnv failed (%d)", status);
            return NULL;
    }
}

void pp_tun_ctrl_test_working_wrapper(void *jni_ref) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "test_working_wrapper(%p)", jni_ref);

    bool did_attach;
    JNIEnv *env = jni_attach_thread(&did_attach);
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
    JNIEnv *env = jni_attach_thread(&did_attach);
    if (!env) return NULL;

    void *result = NULL;
    jclass cls = NULL;
    jstring infoJson = NULL;
    jobject fdObj = NULL;
    jclass integerClass = NULL;
    vpn_impl *impl = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): GetObjectClass returned NULL");
        goto cleanup;
    }

    infoJson = info_json ? (*env)->NewStringUTF(env, info_json) : NULL;
    jmethodID buildMethod = (*env)->GetMethodID(env, cls, sig_build.name, sig_build.signature);
    if (buildMethod == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): build() method not found");
        goto cleanup;
    }

    fdObj = (*env)->CallObjectMethod(env, jni_ref, buildMethod, infoJson);
    if (fdObj == NULL) {
        goto cleanup;
    }

    integerClass = (*env)->FindClass(env, "java/lang/Integer");
    if (integerClass == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): java/lang/Integer class not found");
        goto cleanup;
    }

    jmethodID intValueMethod = (*env)->GetMethodID(env, integerClass, "intValue", "()I");
    if (intValueMethod == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): Integer.intValue() not found");
        goto cleanup;
    }

    const jint fd = (*env)->CallIntMethod(env, fdObj, intValueMethod);

    impl = malloc(sizeof(*impl));
    if (impl == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): malloc failed");
        goto cleanup;
    }
    impl->fd = fd;
    result = impl;

cleanup:
    if (fdObj != NULL) {
        (*env)->DeleteLocalRef(env, fdObj);
    }
    if (integerClass != NULL) {
        (*env)->DeleteLocalRef(env, integerClass);
    }
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
    JNIEnv *env = jni_attach_thread(&did_attach);
    if (!env) return;

    jclass integerCls = NULL;
    jmethodID integerCtor = NULL;
    jobjectArray fdsObj = NULL;
    jobject elem = NULL;
    jclass cls = NULL;
    jmethodID cfgMethod = NULL;

    integerCls = (*env)->FindClass(env, "java/lang/Integer");
    if (integerCls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "configure_sockets(): java/lang/Integer class not found");
        goto cleanup;
    }

    integerCtor = (*env)->GetMethodID(env, integerCls, "<init>", "(I)V");
    if (integerCtor == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "configure_sockets(): Integer constructor not found");
        goto cleanup;
    }

    fdsObj = (*env)->NewObjectArray(env, fds_len, integerCls, NULL);
    if (fdsObj == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "configure_sockets(): failed to allocate Integer[]");
        goto cleanup;
    }

    for (jsize i = 0; i < fds_len; i++) {
        elem = (*env)->NewObject(env, integerCls, integerCtor, (jint)(fds[i]));
        if (elem == NULL) {
            pp_clog_v(PPLogCategoryCore, PPLogLevelError, "configure_sockets(): failed to wrap fd %d", i);
            goto cleanup;
        }
        (*env)->SetObjectArrayElement(env, fdsObj, i, elem);
        (*env)->DeleteLocalRef(env, elem);
        elem = NULL;
    }

    // Call wrapper.configureSockets()
    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "configure_sockets(): GetObjectClass returned NULL");
        goto cleanup;
    }

    cfgMethod = (*env)->GetMethodID(env, cls, sig_configureSockets.name, sig_configureSockets.signature);
    if (cfgMethod == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "configure_sockets(): configureSockets method not found");
        goto cleanup;
    }

    (*env)->CallVoidMethod(env, jni_ref, cfgMethod, fdsObj);

cleanup:
    if (elem != NULL) {
        (*env)->DeleteLocalRef(env, elem);
    }
    if (fdsObj != NULL) {
        (*env)->DeleteLocalRef(env, fdsObj);
    }
    if (integerCls != NULL) {
        (*env)->DeleteLocalRef(env, integerCls);
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
    JNIEnv *env = jni_attach_thread(&did_attach);
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
    JNIEnv *env = jni_attach_thread(&did_attach);
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
