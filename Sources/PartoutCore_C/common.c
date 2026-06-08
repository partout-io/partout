/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdarg.h>
#include <errno.h>
#include "portable/common.h"

const int PPIOErrorWouldBlock   = -11;
const int PPIOErrorNoBufs       = -12;

pp_log_category PPLogCategoryCore = "core";

void pp_clog_v(pp_log_category category,
               pp_log_level level,
               const char *fmt, ...) {
    const int saved_errno = errno;
    va_list args;
    va_start(args, fmt);
    // Add 1 to include the null terminator
    const size_t msg_len = 1 + vsnprintf(NULL, 0, fmt, args);
    char *msg = pp_alloc(msg_len);
    vsnprintf(msg, msg_len, fmt, args);
    va_end(args);
    pp_clog(category, level, msg);
    pp_free(msg);
    errno = saved_errno;
}

#if PARTOUT_ANDROID
#include <android/log.h>

JNIEnv *pp_jni_attach_thread(bool *did_attach) {
    JNIEnv *env;
    jint status = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
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

void *pp_jni_new_global_ref(void *ref) {
    if (!ref) return NULL;

    PP_JNI_ATTACH_OR_RETURN(env, NULL);

    jobject global_ref = (*env)->NewGlobalRef(env, (jobject)ref);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        global_ref = NULL;
    }

    PP_JNI_DETACH(env);
    return global_ref;
}

void pp_jni_delete_global_ref(void *ref) {
    if (!ref) return;

    PP_JNI_ATTACH_OR_RETURN_VOID(env);

    (*env)->DeleteGlobalRef(env, (jobject)ref);

    PP_JNI_DETACH(env);
}

void pp_log_simple_append(const char *tag, pp_log_level level, const char *message) {
    const char *log_tag = tag ? tag : "Partout";
    int android_level = 0;
    switch (level) {
    case PPLogLevelDebug:
        android_level = ANDROID_LOG_VERBOSE;
        break;
    case PPLogLevelInfo:
        android_level = ANDROID_LOG_DEBUG;
        break;
    case PPLogLevelNotice:
        android_level = ANDROID_LOG_INFO;
        break;
    case PPLogLevelError:
        android_level = ANDROID_LOG_WARN;
        break;
    case PPLogLevelFault:
        android_level = ANDROID_LOG_FATAL;
        break;
    }
    __android_log_print(android_level, log_tag, "%s", message);
}
#else
void pp_log_simple_append(const char *tag, pp_log_level level, const char *message) {
    FILE *out = NULL;
    switch (level) {
    case PPLogLevelError:
    case PPLogLevelFault:
        out = stderr;
        break;
    default:
        out = stdout;
        break;
    }
    fprintf(out, "%s[%d]: %s\n", tag ? tag : "Partout", level, message);
}
#endif
