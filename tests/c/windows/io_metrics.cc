// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "io_metrics.h"
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <string>

namespace {
std::string message;
}

extern "C" void winrt_log(winrt_log_level level, const char *format, ...) {
    assert(level == WinrtLogInfo);
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    message = buffer;
}

int main() {
    Partout::IOTiming timing;
    timing.Log(&timing, "empty");
    assert(message.empty());
    timing.Add(std::chrono::nanoseconds(1250));
    timing.Add(std::chrono::nanoseconds(3750));
    timing.Log(&timing, "test");
    assert(message.find("calls=2 total_us=5.000 mean_us=2.500 max_us=3.750") != std::string::npos);
    try {
        Partout::ScopedIOTiming scope(timing);
        throw 1;
    } catch (int) {}
    assert(timing.calls == 3);

    Partout::IOBatches batches;
    batches.Add(1, 100);
    batches.Add(32, 3200);
    batches.Log(&batches, "test");
    assert(message.find("batches=2 packets=33 bytes=3300 singletons=1 mean_packets=16.500 max_packets=32") != std::string::npos);
    puts("I/O metrics tests passed");
}
