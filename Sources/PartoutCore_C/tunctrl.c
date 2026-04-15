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

// This must match Partout pp_tun tun_android.c
typedef struct {
    int fd;
} vpn_impl;

void pp_tun_ctrl_test_working_wrapper(void *jni_ref) {
    pp_clog_v(PPLogCategoryCore, PPLogLevelInfo, "test_working_wrapper(%p)", jni_ref);

    JNIEnv *env;
    (*jvm)->AttachCurrentThread(jvm, &env, NULL);
    jclass cls = (*env)->GetObjectClass(env, jni_ref);
    jmethodID testWorkingMethod = (*env)->GetMethodID(
        env, cls, "testWorking", "()V"
    );
    (*env)->CallVoidMethod(env, jni_ref, testWorkingMethod);
}

void *pp_tun_ctrl_set_tunnel(void *jni_ref, const char *info_json) {
    assert(jni_ref);
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "set_tunnel()");

    JNIEnv *env;
    jint attach_status = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
    if (attach_status != JNI_OK) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): AttachCurrentThread failed (%d)", attach_status);
        return NULL;
    }

    void *result = NULL;
    jclass cls = NULL;
    jstring infoJson = NULL;
    jobject fdObj = NULL;
    jclass integerClass = NULL;
    vpn_impl *impl = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): GetObjectClass returned NULL");
        goto failure;
    }

    infoJson = info_json ? (*env)->NewStringUTF(env, info_json) : NULL;
    jmethodID buildMethod = (*env)->GetMethodID(env, cls, "build", "(Ljava/lang/String;)Ljava/lang/Integer;");
    if (buildMethod == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): build() method not found");
        goto failure;
    }

    fdObj = (*env)->CallObjectMethod(env, jni_ref, buildMethod, infoJson);
    if (fdObj == NULL) {
        goto failure;
    }

    integerClass = (*env)->FindClass(env, "java/lang/Integer");
    if (integerClass == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): java/lang/Integer class not found");
        goto failure;
    }

    jmethodID intValueMethod = (*env)->GetMethodID(env, integerClass, "intValue", "()I");
    if (intValueMethod == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): Integer.intValue() not found");
        goto failure;
    }

    const jint fd = (*env)->CallIntMethod(env, fdObj, intValueMethod);

    impl = malloc(sizeof(*impl));
    if (impl == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelError, "set_tunnel(): malloc failed");
        goto failure;
    }
    impl->fd = fd;
    result = impl;

failure:
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

    return result;
}

void pp_tun_ctrl_configure_sockets(void *jni_ref, const int *fds, const size_t fds_len) {
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "configure_sockets()");
    JNIEnv *env;
    jint attach_status = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
    if (attach_status != JNI_OK) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelError, "configure_sockets(): AttachCurrentThread failed (%d)", attach_status);
        return;
    }

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

    cfgMethod = (*env)->GetMethodID(env, cls, "configureSockets", "([Ljava/lang/Integer;)V");
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
}

void pp_tun_ctrl_clear_tunnel(void *jni_ref, void *tun_impl) {
    assert(jni_ref && tun_impl);
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "clear_tunnel()");

    // Release the tun_impl allocated in set_tunnel
    vpn_impl *impl = tun_impl;
    // Do not close impl->fd, wrapper.close() will take care
    free(impl);

    // Call wrapper.close()
    JNIEnv *env;
    (*jvm)->AttachCurrentThread(jvm, &env, NULL);
    jclass cls = (*env)->GetObjectClass(env, jni_ref);
    jmethodID closeMethod = (*env)->GetMethodID(env, cls, "close", "()V");
    (*env)->CallVoidMethod(env, jni_ref, closeMethod);
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

#endif
