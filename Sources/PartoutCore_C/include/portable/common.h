/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Use inline rather than #define to make available to Swift

static inline
void pp_assert(bool condition) {
    assert(condition);
}

static inline
void *_Nonnull pp_alloc(size_t size) {
    void *memory = calloc(1, size);
    if (!memory) {
        fputs("pp_alloc: malloc() call failed", stderr);
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
#ifdef _WIN32
    char *ptr = _strdup(str);
#else
    char *ptr = strdup(str);
#endif
    if (!ptr) {
        fputs("pp_dup: strdup() call failed", stderr);
        abort();
    }
    return ptr;
}

#ifdef _WIN32
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
