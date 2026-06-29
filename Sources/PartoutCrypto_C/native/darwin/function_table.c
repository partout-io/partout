/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"
#include "../../mbed/crypto_aead_mbed_api.h"
#include "crypto_darwin.h"

pp_crypto_fnt pp_crypto_fnt_native(void) {
    const pp_crypto_enc_fnt enc = {
        pp_darwin_crypto_init_seed,

        pp_mbed_crypto_aead_create,
        pp_mbed_crypto_aead_free,

        pp_darwin_crypto_cbc_create,
        pp_darwin_crypto_cbc_free,

        pp_darwin_crypto_ctr_create,
        pp_darwin_crypto_ctr_free
    };
    pp_crypto_fnt table = pp_crypto_fnt_mbedtls();
    table.name = "native-darwin";
    table.enc = enc;
    return table;
}
