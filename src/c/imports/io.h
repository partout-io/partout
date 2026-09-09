// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <portable/dns.h>
#include <portable/mux.h>
#include <portable/socket.h>
#if defined(_WIN32)
#include <portable/socket_winrt.h>
#endif
#include <portable/tun.h>
