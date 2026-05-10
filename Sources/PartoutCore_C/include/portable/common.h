/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* OS conditionals. */

#if defined(__APPLE__)
#include <TargetConditionals.h>
#define PARTOUT_APPLE       1
#if TARGET_OS_OSX
#define PARTOUT_MACOS       1
#else
#define PARTOUT_MACOS       0
#endif
#else
#define PARTOUT_APPLE       0
#endif

#if defined(__ANDROID__)
#define PARTOUT_ANDROID     1
#define PARTOUT_LINUX       0
#elif defined(__linux__)
#define PARTOUT_ANDROID     0
#define PARTOUT_LINUX       1
#else
#define PARTOUT_ANDROID     0
#define PARTOUT_LINUX       0
#endif

#if defined(_WIN32)
#define PARTOUT_WINDOWS     1
#else
#define PARTOUT_WINDOWS     0
#endif

#if PARTOUT_MACOS || PARTOUT_LINUX || PARTOUT_WINDOWS
#define PARTOUT_ABI         1
#else
#define PARTOUT_ABI         0
#endif

/* Logging counterpart of Swift pp_log. */

typedef enum {
    PPLogLevelFault,
    PPLogLevelError,
    PPLogLevelNotice,
    PPLogLevelInfo,
    PPLogLevelDebug
} pp_log_level;

typedef const char *_Nonnull pp_log_category;
extern pp_log_category PPLogCategoryCore;

extern void pp_clog(pp_log_category category,
                    pp_log_level level,
                    const char *_Nonnull message);

void pp_clog_v(pp_log_category category,
               pp_log_level level,
               const char *_Nonnull fmt, ...);

void pp_log_simple_append(const char *_Nullable tag,
                          pp_log_level level,
                          const char *_Nonnull message);

/* Use inline rather than #define to make available to Swift. */

static inline
void pp_assert(bool condition) {
    assert(condition);
}

static inline
void *_Nonnull pp_alloc(size_t size) {
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
void pp_zero(void *_Nonnull ptr, size_t count) {
#ifdef bzero
    bzero(ptr, count);
#else
    memset(ptr, 0, count);
#endif
}

static inline
char *_Nonnull pp_dup(const char *_Nonnull str) {
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
FILE *_Nullable pp_fopen(const char *_Nonnull filename, const char *_Nonnull mode) {
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

#if PARTOUT_ANDROID
#include <jni.h>
#include <stdbool.h>
extern _Nullable JavaVM *_Nullable jvm;
_Nullable JNIEnv *_Nullable pp_jni_attach_thread(bool *_Nonnull did_attach);
#endif
