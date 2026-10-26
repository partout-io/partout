// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "winrt/log.h"
#include <windows.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <vector>
namespace { std::atomic<winrt_log_callback> logger{nullptr}; }
extern "C" {

void winrt_set_logger(winrt_log_callback callback) { logger.store(callback); }
void winrt_log(winrt_log_level level, const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    const int size = std::vsnprintf(nullptr, 0, format, copy);
    va_end(copy);
    try {
        if (size >= 0) {
            std::vector<char> message(static_cast<size_t>(size) + 1);
            std::vsnprintf(message.data(), message.size(), format, args);
            if (const auto sink = logger.load()) sink(level, message.data());
            else OutputDebugStringA(message.data());
        }
    } catch (...) { /* Diagnostics must not throw across the C ABI. */ }
    va_end(args);
}

}
