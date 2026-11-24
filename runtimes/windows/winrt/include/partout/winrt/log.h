// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <partout/Export.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    WindowsLogFault,
    WindowsLogError,
    WindowsLogNotice,
    WindowsLogInfo,
    WindowsLogDebug
} winrt_log_level;

/* Messages are borrowed until callback return. Callbacks may run concurrently. */
typedef void (*winrt_log_callback)(winrt_log_level level, const char *message);

/* Replace the process-wide sink atomically. Null uses OutputDebugString.
 * Replacement does not drain calls; keep the old sink valid until they return. */
PARTOUT_API void winrt_set_logger(winrt_log_callback callback);

/* Format and deliver a message. Null formats, formatting failures and exceptions
 * are discarded; diagnostics never propagate exceptions to the caller. */
PARTOUT_API void winrt_log(winrt_log_level level, const char *format, ...);

#ifdef __cplusplus
}
#endif
