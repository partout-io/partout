/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/allocation.h"
#include "crypto/keys.h"

#define KeyHMACMaxLength    (size_t)128

bool key_init_seed(const pp_zd *seed) {
    // FIXME: #108, port to Windows CNG
    return true;
}

pp_zd *key_hmac_create() {
    return pp_zd_create(KeyHMACMaxLength);
}

size_t key_hmac_do(key_hmac_ctx *ctx) {
    // FIXME: #108, port to Windows CNG
    return 0;
}

// MARK: -

char *key_decrypted_from_path(const char *path, const char *passphrase) {
    // FIXME: #108, port to Windows CNG
    return NULL;
}

char *key_decrypted_from_pem(const char *pem, const char *passphrase) {
    // FIXME: #108, port to Windows CNG
    return NULL;
}
