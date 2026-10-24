// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
typedef enum { WinrtLogFault, WinrtLogError, WinrtLogNotice, WinrtLogInfo, WinrtLogDebug } winrt_log_level;
/* Process-wide optional sink, matching the hosting application's logger lifetime.
 * Messages are borrowed until callback return. Null uses OutputDebugString. */
typedef void (*winrt_log_callback)(winrt_log_level level, const char *message);
void winrt_set_logger(winrt_log_callback callback);
void winrt_log(winrt_log_level level, const char *format, ...);
#ifdef __cplusplus
}
#endif
