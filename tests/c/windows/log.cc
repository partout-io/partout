// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "windows/log.h"
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace {

std::string message;
windows_log_level level = WindowsLogFault;
unsigned int received = 0;

void receive(windows_log_level value, const char *text) {
    level = value;
    message = text;
    ++received;
}

void fail(windows_log_level, const char *) {
    throw std::runtime_error("Log sink failed");
}

} // namespace

int main() {
    windows_set_logger(receive);
    windows_log(WindowsLogNotice, "%s %d", "packet", 42);
    assert(level == WindowsLogNotice && message == "packet 42" && received == 1);

    const std::string long_message(8192, 'x');
    windows_log(WindowsLogDebug, "%s", long_message.c_str());
    assert(level == WindowsLogDebug && message == long_message && received == 2);

    windows_log(WindowsLogInfo, "");
    assert(message.empty() && received == 3);
    windows_log(WindowsLogError, nullptr);
    assert(received == 3);

    windows_set_logger(fail);
    windows_log(WindowsLogError, "Sink exceptions must not escape");
    windows_set_logger(receive);
    windows_log(WindowsLogInfo, "Delivery resumes after a sink failure");
    assert(received == 4 && message == "Delivery resumes after a sink failure");

    windows_set_logger(nullptr);
    windows_log(WindowsLogDebug, "Windows log test: debugger fallback");
    assert(received == 4);
    puts("Logging tests passed");
}
