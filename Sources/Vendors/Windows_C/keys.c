/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/allocation.h"
#include "crypto/keys.h"

// FIXME: #101, port to Windows CNG

#define KeyHMACMaxLength    (size_t)128

bool key_init_seed(const zeroing_data_t *seed) {
    return true;
}

zeroing_data_t *key_hmac_create() {
    return zd_create(KeyHMACMaxLength);
}

size_t key_hmac_do(key_hmac_ctx *ctx) {
    return 0;
}

// MARK: -

char *key_decrypted_from_path(const char *path, const char *passphrase) {
    return NULL;
}

char *key_decrypted_from_pem(const char *pem, const char *passphrase) {
    return NULL;
}
