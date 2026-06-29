/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"
#include "crypto_windows.h"

pp_crypto_fnt pp_crypto_fnt_native(void) {
    const pp_crypto_enc_fnt enc = {
        pp_windows_crypto_init_seed,

        pp_windows_crypto_aead_create,
        pp_windows_crypto_aead_free,

        pp_windows_crypto_cbc_create,
        pp_windows_crypto_cbc_free,

        pp_windows_crypto_ctr_create,
        pp_windows_crypto_ctr_free
    };
    pp_crypto_fnt table = pp_crypto_fnt_mbedtls();
    table.name = "native-windows";
    table.enc = enc;
    return table;
}
