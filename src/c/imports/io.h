// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <portable/dns.h>
#include <portable/mux.h>
#include <portable/socket.h>
#include <portable/tun.h>
#include <portable/tun_ctrl.h>
#if PARTOUT_WINTUN
#include <winerror.h>
#endif
#if PARTOUT_WINDOWS
#include <partout/winrt/abi.h>
#include <partout/winrt/log.h>
#endif
