/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
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

static JavaVM *jvm = NULL;

JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM* localVM, void* reserved) {
    jvm = localVM;
    return JNI_VERSION_1_6;
}

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

void *pp_tun_ctrl_set_tunnel(void *jni_ref, const pp_tun_ctrl_info *info) {
    assert(jni_ref);
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "set_tunnel()");

    JNIEnv *env;
    (*jvm)->AttachCurrentThread(jvm, &env, NULL);

    // Build input array with remote fds
    jclass integerCls = (*env)->FindClass(env, "java/lang/Integer");
    jmethodID integerCtor = (*env)->GetMethodID(env, integerCls, "<init>", "(I)V");
    const jsize len = info->remote_fds_len;
    jobjectArray remoteFdsObj = (*env)->NewObjectArray(env, len, integerCls, NULL);
    for (jsize i = 0; i < len; i++) {
        jobject elem = (*env)->NewObject(env, integerCls, integerCtor, (jint)(info->remote_fds[i]));
        (*env)->SetObjectArrayElement(env, remoteFdsObj, i, elem);
        (*env)->DeleteLocalRef(env, elem);
    }

    // Call VpnWrapper.build(), returns optional fd (Int?)
    jclass cls = (*env)->GetObjectClass(env, jni_ref);
    jmethodID buildMethod = (*env)->GetMethodID(env, cls, "build", "([Ljava/lang/Integer;)Ljava/lang/Integer;");
    jobject fdObj = (*env)->CallObjectMethod(env, jni_ref, buildMethod, remoteFdsObj);
    if (fdObj == NULL) {
        return NULL;
    }
    jclass integerClass = (*env)->FindClass(env, "java/lang/Integer");
    jmethodID intValueMethod = (*env)->GetMethodID(env, integerClass, "intValue", "()I");
    const jint fd = (*env)->CallIntMethod(env, fdObj, intValueMethod);
    (*env)->DeleteLocalRef(env, integerClass);
    (*env)->DeleteLocalRef(env, fdObj);

    // Return the tun_impl for VirtualTunnelInterface
    vpn_impl *impl = malloc(sizeof(*impl));
    impl->fd = fd;
    return impl;
}

void pp_tun_ctrl_configure_sockets(void *jni_ref, const int *fds, const size_t fds_len) {
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "configure_sockets()");
    JNIEnv *env;
    (*jvm)->AttachCurrentThread(jvm, &env, NULL);

    jclass integerCls = (*env)->FindClass(env, "java/lang/Integer");
    jmethodID integerCtor = (*env)->GetMethodID(env, integerCls, "<init>", "(I)V");
    jobjectArray fdsObj = (*env)->NewObjectArray(env, fds_len, integerCls, NULL);
    for (jsize i = 0; i < fds_len; i++) {
        jobject elem = (*env)->NewObject(env, integerCls, integerCtor, (jint)(fds[i]));
        (*env)->SetObjectArrayElement(env, fdsObj, i, elem);
        (*env)->DeleteLocalRef(env, elem);
    }

    // Call VpnWrapper.configureSockets()
    jclass cls = (*env)->GetObjectClass(env, jni_ref);
    jmethodID cfgMethod = (*env)->GetMethodID(env, cls, "configureSockets", "([Ljava/lang/Integer;)V");
    (*env)->CallVoidMethod(env, jni_ref, cfgMethod, fdsObj);
}

void pp_tun_ctrl_clear_tunnel(void *jni_ref, void *tun_impl) {
    assert(jni_ref && tun_impl);
    pp_clog(PPLogCategoryCore, PPLogLevelInfo, "clear_tunnel()");

    // Release the tun_impl allocated in set_tunnel
    vpn_impl *impl = tun_impl;
    // Do not close impl->fd, PartoutVpnWrapper.close() will take care
    free(impl);

    // Call PartoutVpnWrapper.close()
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

void *pp_tun_ctrl_set_tunnel(void *ref, const pp_tun_ctrl_info *info) {
    (void)ref;
    (void)info;
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
