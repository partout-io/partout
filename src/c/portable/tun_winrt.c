/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/conditionals.h"

#if PARTOUT_WINDOWS
#include "portable/tun_winrt.h"

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current(void) {
    pp_tun_ctrl_fnt fnt = {
        .set_delegate = pp_winrt_tun_ctrl_set_delegate,
        .set_tunnel = pp_winrt_tun_ctrl_set_tunnel,
        .configure_sockets = pp_winrt_tun_ctrl_configure_sockets,
        .report_snapshot = pp_winrt_tun_ctrl_report_snapshot,
        .set_environment_value = pp_winrt_tun_ctrl_set_environment_value,
        .clear_tunnel = pp_winrt_tun_ctrl_clear_tunnel,
        .cancel_tunnel = pp_winrt_tun_ctrl_cancel_tunnel
    };
    return fnt;
}

#endif
