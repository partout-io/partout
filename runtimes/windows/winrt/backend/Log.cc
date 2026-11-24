// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "Log.h"
#include <windows.h>
#include <cstdarg>
#include <cstdio>
#include <vector>
#include <mutex>

namespace {

std::mutex logger_mutex;
partout_init_args core_logger{};

void WriteMessage(partout_log_level level, const char *format, va_list args) noexcept {
    if (!format) return;
    va_list copy;
    va_copy(copy, args);
    const int size = std::vsnprintf(nullptr, 0, format, copy);
    va_end(copy);
    if (size < 0) return;

    try {
        std::vector<char> message(static_cast<size_t>(size) + 1);
        if (std::vsnprintf(message.data(), message.size(), format, args) != size) return;
        partout_init_args sink{};
        {
            std::lock_guard lock(logger_mutex);
            sink = core_logger;
        }
        if (!sink.logger_fn) {
            OutputDebugStringA(message.data());
            return;
        }
        if (static_cast<int>(level) <= sink.log_level)
            sink.logger_fn(sink.logger_ctx, nullptr, level, message.data());
    } catch (...) {
        // Diagnostics must not propagate exceptions to the caller.
    }
}

} // namespace

namespace Partout::Log {

void SetLogger(const partout_init_args *args) {
    std::lock_guard lock(logger_mutex);
    core_logger = args ? *args : partout_init_args{};
}

void Write(partout_log_level level, const char *format, ...) {
    va_list args;
    va_start(args, format);
    WriteMessage(level, format, args);
    va_end(args);
}
} // namespace Partout::Log
