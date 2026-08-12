/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <errno.h>
#include <stdbool.h>

static inline int pp_io_last_error(void) {
    return errno;
}

static inline bool pp_io_wouldblock(void) {
    return errno == EAGAIN || errno == EWOULDBLOCK;
}

static inline bool pp_io_nobufs(void) {
    return errno == ENOBUFS;
}

static inline bool pp_io_nospace(void) {
    return errno == ENOSPC;
}

#define PP_IO_RETRY(result, fn) \
    do { \
        do { \
            (result) = (fn); \
        } while ((result) < 0 && errno == EINTR); \
    } while (0)

static inline int pp_io_handle_result(int result) {
    if (result < 0) {
        if (pp_io_wouldblock()) {
            return PPIOErrorWouldBlock;
        }
        if (pp_io_nobufs()) {
            return PPIOErrorNoBufs;
        }
        if (pp_io_nospace()) {
            return PPIOErrorNoSpace;
        }
    }
    return result;
}
