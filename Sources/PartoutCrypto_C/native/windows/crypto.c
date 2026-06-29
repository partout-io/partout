/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/crypto.h"
#include "crypto_windows.h"

bool pp_windows_crypto_init_seed(const uint8_t *src, const size_t len) {
    (void)src;
    (void)len;
    return true;
}
