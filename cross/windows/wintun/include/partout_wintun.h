// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "partout.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Historical adapter-only implementation; does not configure routes or DNS. */
partout_controller_functions partout_wintun_controller_functions(void);
#ifdef __cplusplus
}
#endif
