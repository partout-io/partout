// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <cstddef>
#include <cstdint>

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

using SocketOnReceive = bool (*)(void *, const uint8_t *, size_t, const SocketAddress *, int32_t);
constexpr int SocketEOF = 1;
using TunOnReceive = bool (*)(void *, const uint8_t *, size_t);
} // namespace Partout
