// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

#include "winrt/log.h"
#include <algorithm>
#include <chrono>
#include <cstdint>

namespace Partout {
// Owners serialize updates. Durations are elapsed wall time, not CPU time.
struct IOTiming {
    using Clock = std::chrono::steady_clock;
    uint64_t calls = 0, total_ns = 0, max_ns = 0;

    void Add(Clock::duration elapsed) {
        const auto ns = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count());
        ++calls;
        total_ns += ns;
        max_ns = std::max(max_ns, ns);
    }

    void Log(const void *owner, const char *stage) const {
        if (!calls) return;
        winrt_log(WinrtLogInfo,
                  "IO metrics owner=%p stage=%s calls=%llu total_us=%.3f mean_us=%.3f max_us=%.3f",
                  owner, stage, calls, total_ns / 1000.0, total_ns / (1000.0 * calls), max_ns / 1000.0);
    }
};

// Records failed/throwing calls too. Scope only the operation named in the log.
class ScopedIOTiming {
public:
    explicit ScopedIOTiming(IOTiming &timing) : timing_(timing), start_(IOTiming::Clock::now()) {}
    ~ScopedIOTiming() { timing_.Add(IOTiming::Clock::now() - start_); }
    ScopedIOTiming(const ScopedIOTiming &) = delete;
    ScopedIOTiming &operator=(const ScopedIOTiming &) = delete;

private:
    IOTiming &timing_;
    IOTiming::Clock::time_point start_;
};

struct IOBatches {
    uint64_t batches = 0, packets = 0, bytes = 0, singletons = 0, max_packets = 0;

    void Add(size_t count, size_t size) {
        ++batches;
        packets += count;
        bytes += size;
        if (count == 1) ++singletons;
        max_packets = std::max(max_packets, static_cast<uint64_t>(count));
    }

    void Log(const void *owner, const char *stage) const {
        if (!batches) return;
        winrt_log(WinrtLogInfo,
                  "IO metrics owner=%p stage=%s batches=%llu packets=%llu bytes=%llu "
                  "singletons=%llu mean_packets=%.3f max_packets=%llu",
                  owner, stage, batches, packets, bytes, singletons,
                  static_cast<double>(packets) / batches, max_packets);
    }
};
} // namespace Partout
