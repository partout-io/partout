/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"

pp_crypto_function_table pp_crypto_function_table_native(void) {
    return pp_crypto_function_table_mbed();
}
