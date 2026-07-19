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
const int PPIOErrorNoSpace      = -13;

void pp_clog_v(pp_log_level level, const char *fmt, ...) {
#if !PARTOUT_WINDOWS
    const int saved_errno = errno;
#endif
    va_list args;
    va_start(args, fmt);
    const int formatted_len = vsnprintf(NULL, 0, fmt, args);
    va_end(args);
    if (formatted_len < 0) {
#if !PARTOUT_WINDOWS
        errno = saved_errno;
#endif
        return;
    }
    const size_t msg_len = (size_t)formatted_len + 1;
    char *msg = pp_alloc(msg_len);
    va_start(args, fmt);
    vsnprintf(msg, msg_len, fmt, args);
    va_end(args);
    partout_log(level, msg);
    pp_free(msg);
#if !PARTOUT_WINDOWS
    errno = saved_errno;
#endif
}

static FILE *pp_file_open_read(const char *path) {
#ifdef _WIN32
    FILE *file = NULL;
    return (fopen_s(&file, path, "rb") == 0) ? file : NULL;
#else
    return fopen(path, "rb");
#endif
}

char *pp_file_read(const char *rel_path, const char *parent) {
    char *abs_path = NULL;
    FILE *file = NULL;
    char *buffer = NULL;

    /* Prepend parent if not NULL. */
    if (parent) {
        const int path_len = snprintf(NULL, 0, "%s/%s", parent, rel_path);
        if (path_len < 0) goto failure;
        abs_path = calloc(1, path_len + 1);
        if (!abs_path) goto failure;
        snprintf(abs_path, path_len + 1, "%s/%s", parent, rel_path);
    } else {
        abs_path = pp_dup(rel_path);
        if (!abs_path) goto failure;
    }

    /* Open file at absolute path. */
    file = pp_file_open_read(abs_path);
    if (!file) goto failure;
    free(abs_path);
    abs_path = NULL;

    /* Compute file size. */
    if (fseek(file, 0, SEEK_END) != 0) goto failure;
    long size = ftell(file);
    if (size < 0) goto failure;
    rewind(file);

    /* Allocate buffer (+1 for '\0'). */
    size_t buffer_size = (size_t)size;
    if ((long)buffer_size != size) goto failure;
    if (buffer_size > SIZE_MAX - 1) goto failure;
    buffer = malloc(buffer_size + 1);
    if (!buffer) goto failure;
    size_t read_size = fread(buffer, 1, buffer_size, file);
    fclose(file);
    file = NULL;

    if (read_size != buffer_size) goto failure;
    buffer[buffer_size] = '\0';
    return buffer;
failure:
    if (buffer) free(buffer);
    if (file) fclose(file);
    if (abs_path) free(abs_path);
    return NULL;
}

#if PARTOUT_ANDROID
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
                pp_clog_v(PPLogLevelFault, "AttachCurrentThread failed (%d)", status);
                return NULL;
            }
            *did_attach = true;
            return env;
        default:
            pp_clog_v(PPLogLevelFault, "GetEnv failed (%d)", status);
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

#endif

#if !PARTOUT_WINDOWS
#include <fcntl.h>

int pp_fd_set_nonblocking(pp_fd fd, int *original_flags) {
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        pp_clog(PPLogLevelFault, "fcntl(): set, F_GETFL");
        return -1;
    }
    if (original_flags) {
        *original_flags = flags;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        pp_clog(PPLogLevelFault, "fcntl(): set, F_SETFL");
        return -1;
    }
    return 0;
}

int pp_fd_restore_blocking(pp_fd fd, int original_flags) {
    if (fcntl(fd, F_SETFL, original_flags) < 0) {
        pp_clog(PPLogLevelFault, "fcntl(): restore");
        return -1;
    }
    return 0;
}
#endif
