/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
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
