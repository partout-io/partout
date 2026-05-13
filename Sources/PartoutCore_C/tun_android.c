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
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

struct __pp_tun_struct {
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

/* JNI */

typedef struct {
    const char *name;
    const char *signature;
} kotlin_sig;

#define JNI_ATTACH_OR_RETURN(env_name, return_value) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) return return_value

#define JNI_ATTACH_OR_RETURN_VOID(env_name) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) return

#define JNI_ATTACH_OR_COMPLETE(env_name, completion, ctx) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) { \
        if (completion) completion(ctx, -1); \
        return; \
    }

#define JNI_DETACH(env_name) \
    do { \
        if (env_name##_did_attach) (*jvm)->DetachCurrentThread(jvm); \
    } while (0)

/* Tunnel controller (AndroidTunnelController) */

static const kotlin_sig sig_ctrl_testWorking = {
    "testWorking",
    "()V"
};
static const kotlin_sig sig_ctrl_setTunnel = {
    "setTunnel",
    "(Ljava/lang/String;)I"
};
static const kotlin_sig sig_ctrl_configureSockets = {
    "configureSockets",
    "([I)V"
};

void pp_tun_ctrl_test_working(void *jni_ref) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_test_working(%p)", jni_ref);

    JNI_ATTACH_OR_RETURN_VOID(env);

    jclass cls = NULL;
    jmethodID method = NULL;
    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_test_working(), NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_ctrl_testWorking.name, sig_ctrl_testWorking.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_test_working(), NULL method");
        goto cleanup;
    }
    (*env)->CallVoidMethod(env, jni_ref, method);

cleanup:
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    JNI_DETACH(env);
}

pp_tun pp_tun_ctrl_set_tunnel(void *jni_ref, const char *uuid, const char *info_json) {
    (void)uuid;
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_set_tunnel(%p)", jni_ref);

    JNI_ATTACH_OR_RETURN(env, NULL);

    jclass cls = NULL;
    jmethodID method = NULL;
    jstring j_info_json = NULL;

    // This will be the result on success
    pp_tun tun_impl = malloc(sizeof(*tun_impl));
    if (tun_impl == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_set_tunnel(), NULL tun_impl");
        goto cleanup;
    }
    tun_impl->fd = -1;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_set_tunnel(), NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_ctrl_setTunnel.name, sig_ctrl_setTunnel.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_set_tunnel(), NULL method");
        goto cleanup;
    }
    j_info_json = info_json ? (*env)->NewStringUTF(env, info_json) : NULL;
    tun_impl->fd = (*env)->CallIntMethod(env, jni_ref, method, j_info_json);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_set_tunnel(), Kotlin exception");
        tun_impl->fd = -1;
        goto cleanup;
    }
    if (tun_impl->fd < 0) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_set_tunnel(), Invalid fd");
        goto cleanup;
    }
cleanup:
    if (tun_impl != NULL && tun_impl->fd < 0) {
        free(tun_impl);
        tun_impl = NULL;
    }
    if (j_info_json != NULL) (*env)->DeleteLocalRef(env, j_info_json);
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    JNI_DETACH(env);
    return tun_impl;
}

void pp_tun_ctrl_configure_sockets(void *jni_ref, const int *fds, const size_t fds_len) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_configure_sockets(%p)", jni_ref);
    if (!fds || fds_len == 0) return;

    JNI_ATTACH_OR_RETURN_VOID(env);

    jclass cls = NULL;
    jmethodID method = NULL;
    jintArray j_fds = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_configure_sockets(), NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_ctrl_configureSockets.name, sig_ctrl_configureSockets.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_configure_sockets(), NULL method");
        goto cleanup;
    }
    j_fds = (*env)->NewIntArray(env, (jsize)fds_len);
    if (j_fds == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_configure_sockets(), NULL j_fds");
        goto cleanup;
    }
    (*env)->SetIntArrayRegion(env, j_fds, 0, (jsize)fds_len, (const jint *)fds);
    (*env)->CallVoidMethod(env, jni_ref, method, j_fds);

cleanup:
    if (j_fds != NULL) (*env)->DeleteLocalRef(env, j_fds);
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    JNI_DETACH(env);
}

void pp_tun_ctrl_clear_tunnel(void *jni_ref, pp_tun tun_impl) {
    (void)jni_ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_clear_tunnel(%p)", jni_ref);
    if (!tun_impl) return;
    pp_tun_shutdown(tun_impl);
    free(tun_impl);
}

/* Tunnel strategy (AndroidTunnel) */

static const kotlin_sig sig_strg_connect = {
    "connect",
    "(Ljava/lang/String;JJ)V"
};
static const kotlin_sig sig_strg_disconnect = {
    "disconnect",
    "(JJ)V"
};

void pp_tun_strg_install(void *jni_ref,
                         const char *profile_json,
                         bool connect,
                         const char *options_json,
                         void *ctx,
                         pp_completion completion) {
    (void)options_json;
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: strg_install(%p, %d)", jni_ref, connect);

    /* Install-only is nop on Android. */
    if (!connect) {
        if (completion) completion(ctx, 0);
        return;
    }

    JNI_ATTACH_OR_COMPLETE(env, completion, ctx);

    jclass cls = NULL;
    jmethodID method = NULL;
    jstring j_profile_json = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: strg_install(), NULL cls");
        if (completion) completion(ctx, -1);
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_strg_connect.name, sig_strg_connect.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: strg_install(), NULL method");
        if (completion) completion(ctx, -1);
        goto cleanup;
    }
    j_profile_json = (*env)->NewStringUTF(env, profile_json);
    if (j_profile_json == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: strg_install(), NULL j_profile_json");
        if (completion) completion(ctx, -1);
        goto cleanup;
    }
    (*env)->CallVoidMethod(
        env,
        jni_ref,
        method,
        j_profile_json,
        (jlong)(intptr_t)ctx,
        (jlong)(intptr_t)completion
    );
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: strg_install(), Kotlin exception");
        if (completion) completion(ctx, -1);
        goto cleanup;
    }

cleanup:
    if (j_profile_json != NULL) (*env)->DeleteLocalRef(env, j_profile_json);
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    JNI_DETACH(env);
}

void pp_tun_strg_uninstall(void *jni_ref,
                           const char *profile_id,
                           void *ctx,
                           pp_completion completion) {
    (void)jni_ref;
    (void)profile_id;
    /* Uninstall is nop on Android. */
    if (completion) completion(ctx, 0);
}

void pp_tun_strg_disconnect(void *jni_ref,
                            const char *profile_id,
                            void *ctx,
                            pp_completion completion) {
    (void)profile_id;
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: strg_disconnect(%p)", jni_ref);

    JNI_ATTACH_OR_COMPLETE(env, completion, ctx);

    jclass cls = NULL;
    jmethodID method = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: strg_disconnect(), NULL cls");
        if (completion) completion(ctx, -1);
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_strg_disconnect.name, sig_strg_disconnect.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: strg_disconnect(), NULL method");
        if (completion) completion(ctx, -1);
        goto cleanup;
    }
    (*env)->CallVoidMethod(
        env,
        jni_ref,
        method,
        (jlong)(intptr_t)ctx,
        (jlong)(intptr_t)completion
    );
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: strg_disconnect(), Kotlin exception");
        if (completion) completion(ctx, -1);
        goto cleanup;
    }

cleanup:
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    JNI_DETACH(env);
}

JNIEXPORT void JNICALL
Java_io_partout_jni_AndroidTunnel_callback(JNIEnv *env,
                                           jobject thiz,
                                           jlong completion_ctx,
                                           jlong completion,
                                           jint error_code) {
    (void)env;
    (void)thiz;
    void *ctx = (void *)(intptr_t)completion_ctx;
    pp_completion cb = (pp_completion)(intptr_t)completion;
    if (cb) cb(ctx, (int)error_code);
}

#endif
