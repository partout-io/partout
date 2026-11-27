// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <partout/Export.h>
#include <partout/models/TaggedProfile.h>
#include <optional>
#include <string>

namespace Partout::Runtime {
enum class LogLevel { Fault, Error, Notice, Info, Debug };

struct InitializationOptions final {
    LogLevel log_level = LogLevel::Debug;
    bool logs_private_data = false;
    // Strings are borrowed during the call. The context must remain alive while
    // registered with the process-wide logger; callbacks must not throw.
    void (*logger_fn)(void *, const char *, int, const char *) noexcept = nullptr;
    void *logger_ctx = nullptr;
};

PARTOUT_RUNTIME_API void Initialize(const InitializationOptions &options);

// Throws a sanitized runtime_error on import failure, without configuration data.
PARTOUT_RUNTIME_API Models::TaggedProfile ImportProfile(
    const std::string &text,
    const std::optional<std::string> &name = std::nullopt,
    const std::optional<std::string> &profile_id = std::nullopt
);

// Base64 input/output. Returns nullopt for invalid keys or unavailable WireGuard.
PARTOUT_RUNTIME_API std::optional<std::string> WireGuardPublicKey(const std::string &private_key);
}
