// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "partout.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Minimal command-line controller. Preserves existing TUN-only behavior;
 * host routing and DNS configuration are not implemented here. */
partout_controller_functions partout_posix_controller_functions(void);
#ifdef __cplusplus
}
#endif
