/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"

pp_crypto_fnt pp_crypto_fnt_native(void) {
    return pp_crypto_fnt_mbedtls();
}
