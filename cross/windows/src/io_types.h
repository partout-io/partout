// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "winrt/runtime.h"

namespace Partout {
enum SocketProto { SocketProtoTCP, SocketProtoUDP };
struct SocketOpenOptions { bool dual_stack; int timeout_ms; };
using SocketAddress = winrt_address;
using SocketOnReceive = winrt_receive;
constexpr int SocketEOF = WinrtEOF;
using TunOnReceive = bool (*)(void *, const uint8_t *, size_t);
}
