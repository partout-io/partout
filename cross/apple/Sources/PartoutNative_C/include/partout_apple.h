// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "partout.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Finds and duplicates the NetworkExtension descriptor. The core owns the copy. */
partout_tun partout_tun_lookup(void);

#ifdef __cplusplus
}
#endif
