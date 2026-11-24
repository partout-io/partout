// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <partout/winrt/log.h>
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace {

std::string message;
winrt_log_level level = WindowsLogFault;
unsigned int received = 0;

void receive(winrt_log_level value, const char *text) {
    level = value;
    message = text;
    ++received;
}

void fail(winrt_log_level, const char *) {
    throw std::runtime_error("Log sink failed");
}

} // namespace

int main() {
    winrt_set_logger(receive);
    winrt_log(WindowsLogNotice, "%s %d", "packet", 42);
    assert(level == WindowsLogNotice && message == "packet 42" && received == 1);

    const std::string long_message(8192, 'x');
    winrt_log(WindowsLogDebug, "%s", long_message.c_str());
    assert(level == WindowsLogDebug && message == long_message && received == 2);

    winrt_log(WindowsLogInfo, "");
    assert(message.empty() && received == 3);
    winrt_log(WindowsLogError, nullptr);
    assert(received == 3);

    winrt_set_logger(fail);
    winrt_log(WindowsLogError, "Sink exceptions must not escape");
    winrt_set_logger(receive);
    winrt_log(WindowsLogInfo, "Delivery resumes after a sink failure");
    assert(received == 4 && message == "Delivery resumes after a sink failure");

    winrt_set_logger(nullptr);
    winrt_log(WindowsLogDebug, "Windows log test: debugger fallback");
    assert(received == 4);
    puts("Logging tests passed");
}
