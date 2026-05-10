/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdarg.h>
#include "portable/common.h"

pp_log_category PPLogCategoryCore = "core";

void pp_clog_v(pp_log_category category,
               pp_log_level level,
               const char *_Nonnull fmt, ...) {
    va_list args;
    va_start(args, fmt);
    // Add 1 to include the null terminator
    const size_t msg_len = 1 + vsnprintf(NULL, 0, fmt, args);
    char *msg = pp_alloc(msg_len);
    vsnprintf(msg, msg_len, fmt, args);
    va_end(args);
    pp_clog(category, level, msg);
    pp_free(msg);
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

void pp_log_simple_append(const char *tag, pp_log_level level, const char *_Nonnull message) {
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
void pp_log_simple_append(const char *tag, pp_log_level level, const char *_Nonnull message) {
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
