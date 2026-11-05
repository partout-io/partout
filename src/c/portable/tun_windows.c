/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */

#include "portable/tun.h"

#if PARTOUT_WINDOWS
#if PARTOUT_WINDOWS_RUNTIME
#include "windows/abi.h"
#endif
void pp_tun_free(pp_tun tun) {
    if (!tun) return;
#if PARTOUT_WINDOWS_RUNTIME
    windows_transport *transport = (windows_transport *)tun;
    transport->release(transport->context);
#else
    pp_free(tun);
#endif
}
#endif
