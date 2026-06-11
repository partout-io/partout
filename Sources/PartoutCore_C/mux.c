/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/mux.h"
#include "portable/common.h"

const int PPMuxErrorNull = -2;

#if PARTOUT_WINDOWS
#include "portable/mux_windows.h"
#else
#include "portable/mux_posix.h"
#endif
