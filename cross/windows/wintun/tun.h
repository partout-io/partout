// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "partout.h"

/* Private to the Wintun controller library. */
partout_tun wintun_open(const char *uuid);
