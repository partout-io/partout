/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "portable/conditionals.h"

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma clang assume_nonnull begin

/* Logging counterpart of Swift pp_log. */

typedef enum {
    PPLogLevelFault,
    PPLogLevelError,
    PPLogLevelNotice,
    PPLogLevelInfo,
    PPLogLevelDebug
} pp_log_level;

typedef const char *pp_log_category;
extern pp_log_category PPLogCategoryCore;

extern void pp_clog(pp_log_category category,
                    pp_log_level level,
                    const char *message);

void pp_clog_v(pp_log_category category,
               pp_log_level level,
               const char *fmt, ...);

void pp_log_simple_append(const char *_Nullable tag,
                          pp_log_level level,
                          const char *message);

typedef void (*pp_completion)(void *_Nullable ctx, const int error_code);

/* Use inline rather than #define to make available to Swift. */

static inline
void pp_assert(bool condition) {
    assert(condition);
}

static inline
void *pp_alloc(size_t size) {
    void *memory = calloc(1, size);
    if (!memory) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_alloc: malloc() call failed");
        abort();
    }
    return memory;
}

static inline
void pp_free(void *_Nullable ptr) {
    if (!ptr) return;
    free(ptr);
}

static inline
void pp_zero(void *ptr, size_t count) {
#ifdef bzero
    bzero(ptr, count);
#else
    memset(ptr, 0, count);
#endif
}

static inline
char *pp_dup(const char *str) {
#if PARTOUT_WINDOWS
    char *ptr = _strdup(str);
#else
    char *ptr = strdup(str);
#endif
    if (!ptr) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_dup: strdup() call failed");
        abort();
    }
    return ptr;
}

#if PARTOUT_WINDOWS
static inline
FILE *_Nullable pp_fopen(const char *filename, const char *mode) {
    FILE *file_ret = NULL;
    errno_t file_err = fopen_s(&file_ret, filename, mode);
    if (file_err == 0) {
        return NULL;
    }
    return file_ret;
}
#define pp_sscanf sscanf_s
#else
#define pp_fopen fopen
#define pp_sscanf sscanf
#endif

/* Syscalls. */
#define PP_IO_RETRY(result, fn) \
    do { \
        do { \
            (result) = (fn); \
        } while ((result) < 0 && errno == EINTR); \
    } while (0)

#pragma clang assume_nonnull end

/* Android only. */

#if PARTOUT_ANDROID
#include <android/multinetwork.h>
#include <jni.h>

#pragma clang assume_nonnull begin

extern _Nullable JavaVM *_Nullable jvm;
_Nullable JNIEnv *_Nullable pp_jni_attach_thread(bool *did_attach);
void *_Nullable pp_jni_new_global_ref(void *_Nullable ref);
void pp_jni_delete_global_ref(void *_Nullable ref);

#define PP_JNI_ATTACH_OR_RETURN(env_name, return_value) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) return return_value

#define PP_JNI_ATTACH_OR_RETURN_VOID(env_name) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) return

#define PP_JNI_ATTACH_OR_COMPLETE(env_name, completion, ctx) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) { \
        if (completion) completion(ctx, -1); \
        return; \
    }

#define PP_JNI_DETACH(env_name) \
    do { \
        if (env_name##_did_attach) (*jvm)->DetachCurrentThread(jvm); \
    } while (0)

#pragma clang assume_nonnull end

#endif
