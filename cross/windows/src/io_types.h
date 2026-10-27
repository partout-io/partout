// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>

namespace Partout {
enum SocketProto { SocketProtoTCP, SocketProtoUDP };

struct SocketOpenOptions {
    bool dual_stack;
    int timeout_ms;
};

struct SocketAddress {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
};

using SocketOnReceive = std::function<bool(const uint8_t *, size_t, const SocketAddress *, int32_t)>;
constexpr int SocketEOF = 1;
using TunOnReceive = std::function<bool(const uint8_t *, size_t, int32_t)>;
} // namespace Partout
