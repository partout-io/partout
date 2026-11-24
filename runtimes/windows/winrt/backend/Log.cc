// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "Log.h"
#include <windows.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <vector>
#include <mutex>

namespace {

std::atomic<winrt_log_callback> logger{nullptr};
std::mutex logger_mutex;
partout_init_args core_logger{};

void SetLogger(winrt_log_callback callback) noexcept {
    {
        std::lock_guard lock(logger_mutex);
        core_logger = {};
    }
    logger.store(callback);
}

void Log(winrt_log_level level, const char *format, va_list args) noexcept {
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
            partout_init_args args{};
            {
                std::lock_guard lock(logger_mutex);
                args = core_logger;
            }
            if (args.logger_fn) {
                if (static_cast<int>(level) <= static_cast<int>(args.log_level))
                    args.logger_fn(args.logger_ctx, nullptr, static_cast<partout_log_level>(level), message.data());
                return;
            }
            OutputDebugStringA(message.data());
            return;
        }
        sink(level, message.data());
    } catch (...) {
        // Diagnostics must not throw across the C ABI.
    }
}

} // namespace

extern "C" {

void winrt_set_core_logger(const partout_init_args *args) {
    std::lock_guard lock(logger_mutex);
    core_logger = args ? *args : partout_init_args{};
    logger.store(nullptr);
}

void winrt_set_logger(winrt_log_callback callback) {
    SetLogger(callback);
}

void winrt_log(winrt_log_level level, const char *format, ...) {
    va_list args;
    va_start(args, format);
    Log(level, format, args);
    va_end(args);
}
}
