/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

static inline int pp_io_last_error(void) {
    return (int)GetLastError();
}
