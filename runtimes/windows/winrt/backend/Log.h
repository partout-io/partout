// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <partout.h>

namespace Partout::Log {

/* Replace the process-wide sink atomically. Null uses OutputDebugString.
 * Replacement does not drain calls; keep the old sink valid until they return. */
void SetLogger(const partout_init_args *args);

/* Format and deliver a message. Null formats, formatting failures and exceptions
 * are discarded; diagnostics never propagate exceptions to the caller. */
void Write(partout_log_level level, const char *format, ...);

} // namespace Partout::Log
