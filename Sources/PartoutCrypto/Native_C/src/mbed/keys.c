/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <mbedtls/pem.h>
#include "portable/common.h"
#include "crypto/keys.h"

char *pp_key_decrypted_from_path(const char *path, const char *passphrase) {
    // FIXME: #108, implement with mbedTLS
    return NULL;
}

char *pp_key_decrypted_from_pem(const char *pem, const char *passphrase) {
    // FIXME: #108, implement with mbedTLS
    return NULL;
}
