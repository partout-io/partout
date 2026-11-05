// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "windows/log.h"
#include <windows.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <vector>

namespace Partout {
namespace {

std::atomic<windows_log_callback> logger{nullptr};

void SetLogger(windows_log_callback callback) noexcept {
    logger.store(callback);
}

void Log(windows_log_level level, const char *format, va_list args) noexcept {
    if (!format) return;
    va_list copy;
    va_copy(copy, args);
    const int size = std::vsnprintf(nullptr, 0, format, copy);
    va_end(copy);
    if (size < 0) return;

    try {
        std::vector<char> message(static_cast<size_t>(size) + 1);
        if (std::vsnprintf(message.data(), message.size(), format, args) != size) return;
        const auto sink = logger.load();
        if (!sink) {
            OutputDebugStringA(message.data());
            return;
        }
        sink(level, message.data());
    } catch (...) {
        // Diagnostics must not throw across the C ABI.
    }
}

} // namespace
} // namespace Partout

extern "C" {

void windows_set_logger(windows_log_callback callback) {
    Partout::SetLogger(callback);
}

void windows_log(windows_log_level level, const char *format, ...) {
    va_list args;
    va_start(args, format);
    Partout::Log(level, format, args);
    va_end(args);
}
}
