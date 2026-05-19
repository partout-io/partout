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

/* Tunnel controller (PartoutVpnServiceRuntime) */

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
static const kotlin_sig sig_ctrl_onSnapshot = {
    "onSnapshot",
    "(Ljava/lang/String;)V"
};
static const kotlin_sig sig_ctrl_cancelTunnel = {
    "cancelTunnel",
    "(Ljava/lang/String;)V"
};

void pp_tun_ctrl_test_working(void *jni_ref) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_test_working(%p)", jni_ref);

    PP_JNI_ATTACH_OR_RETURN_VOID(env);

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
    PP_JNI_DETACH(env);
}

pp_tun pp_tun_ctrl_set_tunnel(void *jni_ref, const char *uuid, const char *info_json) {
    (void)uuid;
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_set_tunnel(%p)", jni_ref);

    PP_JNI_ATTACH_OR_RETURN(env, NULL);

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
    PP_JNI_DETACH(env);
    return tun_impl;
}

void pp_tun_ctrl_configure_sockets(void *jni_ref, const int *fds, const size_t fds_len) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_configure_sockets(%p)", jni_ref);
    if (!fds || fds_len == 0) return;

    PP_JNI_ATTACH_OR_RETURN_VOID(env);

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
    PP_JNI_DETACH(env);
}

void pp_tun_ctrl_report_snapshot(void *_Nullable ref,
                                 const char *_Nonnull snapshot_json) {
    assert(ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_report_snapshot(%p)", ref);

    PP_JNI_ATTACH_OR_RETURN_VOID(env);

    jclass cls = NULL;
    jmethodID method = NULL;
    jstring j_snapshot_json = NULL;

    cls = (*env)->GetObjectClass(env, ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_report_snapshot(), NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_ctrl_onSnapshot.name, sig_ctrl_onSnapshot.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_report_snapshot(), NULL method");
        goto cleanup;
    }
    j_snapshot_json = (*env)->NewStringUTF(env, snapshot_json);
    if (j_snapshot_json == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_report_snapshot(), NULL j_snapshot_json");
        goto cleanup;
    }
    (*env)->CallVoidMethod(env, ref, method, j_snapshot_json);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_report_snapshot(), Kotlin exception");
        goto cleanup;
    }

cleanup:
    if (j_snapshot_json != NULL) (*env)->DeleteLocalRef(env, j_snapshot_json);
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    PP_JNI_DETACH(env);
}

void pp_tun_ctrl_cancel_tunnel(void *jni_ref, const char *error_message) {
    assert(jni_ref);
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_cancel_tunnel(%p)", jni_ref);

    PP_JNI_ATTACH_OR_RETURN_VOID(env);

    jclass cls = NULL;
    jmethodID method = NULL;
    jstring j_error_message = NULL;

    cls = (*env)->GetObjectClass(env, jni_ref);
    if (cls == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_cancel_tunnel(), NULL cls");
        goto cleanup;
    }
    method = (*env)->GetMethodID(env, cls, sig_ctrl_cancelTunnel.name, sig_ctrl_cancelTunnel.signature);
    if (method == NULL) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_cancel_tunnel(), NULL method");
        goto cleanup;
    }
    j_error_message = error_message ? (*env)->NewStringUTF(env, error_message) : NULL;
    (*env)->CallVoidMethod(env, jni_ref, method, j_error_message);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "tun_android: ctrl_cancel_tunnel(), Kotlin exception");
        goto cleanup;
    }

cleanup:
    if (j_error_message != NULL) (*env)->DeleteLocalRef(env, j_error_message);
    if (cls != NULL) (*env)->DeleteLocalRef(env, cls);
    PP_JNI_DETACH(env);
}

void pp_tun_ctrl_clear_tunnel(void *jni_ref, pp_tun tun_impl) {
    (void)jni_ref;
    pp_clog_v(PPLogCategoryCore, PPLogLevelDebug, "tun_android: ctrl_clear_tunnel(%p)", jni_ref);
    if (!tun_impl) return;
    pp_tun_shutdown(tun_impl);
    free(tun_impl);
}

#endif
