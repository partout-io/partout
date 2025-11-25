/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/rand.h>
#include "crypto/crypto.h"

bool pp_crypto_init_seed(const uint8_t *_Nonnull src, const size_t len) {
    unsigned char x[1];
    if (RAND_bytes(x, 1) != 1) {
        return false;
    }
    RAND_seed(src, (int)len);
    return true;
}
