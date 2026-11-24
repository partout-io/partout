// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "backend/Log.h"
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace {

std::string message;
int level = PartoutLogLevelFault;
unsigned int received = 0;

void Receive(void *context, const char *profile_id, int value, const char *text) {
    assert(context == &received && profile_id == nullptr);
    level = value;
    message = text;
    ++received;
}

void Fail(void *, const char *, int, const char *) {
    throw std::runtime_error("Log sink failed");
}

} // namespace

int main() {
    partout_init_args args{};
    args.log_level = PartoutLogLevelDebug;
    args.logger_fn = Receive;
    args.logger_ctx = &received;
    Partout::Log::SetLogger(&args);
    Partout::Log::Write(PartoutLogLevelNotice, "%s %d", "packet", 42);
    assert(level == PartoutLogLevelNotice && message == "packet 42" && received == 1);

    const std::string long_message(8192, 'x');
    Partout::Log::Write(PartoutLogLevelDebug, "%s", long_message.c_str());
    assert(level == PartoutLogLevelDebug && message == long_message && received == 2);

    Partout::Log::Write(PartoutLogLevelInfo, "");
    assert(message.empty() && received == 3);
    Partout::Log::Write(PartoutLogLevelError, nullptr);
    assert(received == 3);

    args.logger_fn = Fail;
    Partout::Log::SetLogger(&args);
    Partout::Log::Write(PartoutLogLevelError, "Sink exceptions must not escape");
    args.logger_fn = Receive;
    Partout::Log::SetLogger(&args);
    Partout::Log::Write(PartoutLogLevelInfo, "Delivery resumes after a sink failure");
    assert(received == 4 && message == "Delivery resumes after a sink failure");

    args.log_level = PartoutLogLevelError;
    Partout::Log::SetLogger(&args);
    Partout::Log::Write(PartoutLogLevelDebug, "Filtered message");
    assert(received == 4);

    Partout::Log::SetLogger(nullptr);
    Partout::Log::Write(PartoutLogLevelDebug, "Windows log test: debugger fallback");
    assert(received == 4);
    puts("Logging tests passed");
}
