/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */

#include "portable/conditionals.h"
#include "portable/tun.h"
#include "portable/tun_ctrl.h"
#include "portable/socket.h"

#if PARTOUT_WINDOWS
#if PARTOUT_WINRT
#include "winrt/abi.h"
#endif
void pp_tun_free(pp_tun tun) {
    if (!tun) return;
#if PARTOUT_WINRT
    winrt_transport *transport = (winrt_transport *)tun;
    transport->release(transport->context);
#else
    pp_free(tun);
#endif
}
#endif
