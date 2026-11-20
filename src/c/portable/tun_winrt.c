/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */

#include "portable/tun.h"

#if PARTOUT_WINDOWS
#if PARTOUT_WINRT
#include "windows/abi.h"
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

// WinRT handles are push transports, not readiness-driven TUN devices.
pp_tun pp_tun_wrap_callbacks(void *ctx, const partout_tun_callbacks *callbacks) {
    (void)ctx;
    (void)callbacks;
    return NULL;
}
