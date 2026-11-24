// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <partout_io.h>
#include <cstddef>
#include <cstdint>
#include <functional>

namespace Partout {
using SocketOnReceive =
    std::function<bool(const uint8_t *, size_t, const partout_socket_address *, int32_t)>;
using TunOnReceive = std::function<bool(const uint8_t *, size_t, int32_t)>;
} // namespace Partout
