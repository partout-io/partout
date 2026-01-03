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

#ifdef __ANDROID__
#include <android/log.h>
void pp_log_simple_append(pp_log_level level, const char *_Nonnull message) {
    const char *log_tag = "Partout";
    int android_level = 0;
    switch (level) {
    case PPLogLevelDebug:
        android_level = ANDROID_LOG_VERBOSE;
    case PPLogLevelInfo:
        android_level = ANDROID_LOG_DEBUG;
    case PPLogLevelNotice:
        android_level = ANDROID_LOG_INFO;
    case PPLogLevelError:
        android_level = ANDROID_LOG_WARN;
    case PPLogLevelFault:
        android_level = ANDROID_LOG_FATAL;
    }
    __android_log_print(android_level, log_tag, "%s", message);
}
#else
void pp_log_simple_append(pp_log_level level, const char *_Nonnull message) {
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
    fprintf(out, "Partout[%d]: %s\n", level, message);
}
#endif
