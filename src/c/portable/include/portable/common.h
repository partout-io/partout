/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "conditionals.h"

#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
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

/* This callback forwards to the logger from partout_init(). */
// extern bool partout_log_enabled(void);
extern void partout_log(pp_log_level level, const char *message);

static inline
void pp_clog(pp_log_level level, const char *message) {
    partout_log(level, message);
}

/* Use inline rather than #define to make available to Swift. */

static inline
void pp_assert(bool condition) {
    assert(condition);
    (void)condition;
}

static inline
void *pp_alloc(size_t size) {
    void *memory = calloc(1, size);
    if (!memory) {
        pp_clog(PPLogLevelFault, "pp_alloc: malloc() call failed");
        abort();
    }
    return memory;
}

static inline
void pp_free(void *_Nullable ptr) {
    if (!ptr) return;
    free(ptr);
}

/* Header-local so controller libraries share formatting without a private DLL export. */
static inline
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

static inline
void pp_zero(void *ptr, size_t count) {
#ifdef bzero
    bzero(ptr, count);
#else
    memset(ptr, 0, count);
#endif
}

char *pp_dup(const char *str);
FILE *_Nullable pp_fopen(const char *filename, const char *mode);

/* Read a whole file into a string. */
char *_Nullable pp_file_read(const char *rel_path, const char *_Nullable parent);

/* Create a directory and any missing parents. Existing directories succeed. */
bool pp_file_create_directory(const char *path);

/* Return whether a path identifies a directory. */
bool pp_file_is_directory(const char *path);

/* Return seconds since the Unix epoch, or zero if unavailable. */
uint32_t pp_time_unix_seconds(void);

/* Report a fatal Zig error without pulling in Zig's default I/O backend. */
void pp_panic(const char *message);

#pragma clang assume_nonnull end

/* Syscalls. */

extern const int PPIOErrorWouldBlock;
extern const int PPIOErrorNoBufs;
extern const int PPIOErrorNoSpace;

#pragma clang assume_nonnull begin

#if PARTOUT_WINDOWS

/* ABI-compatible with the Windows SDK HANDLE and SOCKET definitions. */
typedef void *_Nonnull pp_fd;
typedef uintptr_t pp_socket_fd;

static inline pp_fd pp_fd_invalid(void) {
    return ((pp_fd)(void *)0);
}

/* Reject both NULL and INVALID_HANDLE_VALUE. */
static inline bool pp_fd_is_valid(pp_fd fd) {
    return fd && (intptr_t)fd != -1;
}

#else

typedef int pp_fd;
typedef pp_fd pp_socket_fd;

static inline pp_fd pp_fd_invalid(void) {
    return -1;
}

static inline bool pp_fd_is_valid(pp_fd fd) {
    return fd != -1;
}

#endif

/* No-op on Windows; original_flags is left unchanged. */
int pp_fd_set_nonblocking(pp_fd fd, int *_Nullable original_flags);

int pp_io_last_error_binding(void);

#pragma clang assume_nonnull end
