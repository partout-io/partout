// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <partout_io.h>
#include <cstddef>
#include <cstdint>
#include <functional>

namespace Partout {
using SocketProto = partout_socket_proto;
constexpr SocketProto SocketProtoTCP = PartoutSocketProtoTCP;
constexpr SocketProto SocketProtoUDP = PartoutSocketProtoUDP;
using SocketOpenOptions = partout_socket_open_options;
using SocketAddress = partout_socket_address;

using SocketOnReceive =
    std::function<bool(const uint8_t *, size_t, const SocketAddress *, int32_t)>;
constexpr int SocketEOF = PartoutTransportEOF;
using TunOnReceive = std::function<bool(const uint8_t *, size_t, int32_t)>;
} // namespace Partout
