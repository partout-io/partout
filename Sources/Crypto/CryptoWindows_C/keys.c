/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "crypto/keys.h"

#define KeyHMACMaxLength    (size_t)128

bool pp_key_init_seed(const pp_zd *seed) {
    // FIXME: #108, port to Windows CNG
    return true;
}

pp_zd *pp_key_hmac_create() {
    return pp_zd_create(KeyHMACMaxLength);
}

size_t pp_key_hmac_do(pp_key_hmac_ctx *ctx) {
    // FIXME: #108, port to Windows CNG
    return 0;
}

// MARK: -

char *pp_key_decrypted_from_path(const char *path, const char *passphrase) {
    // FIXME: #108, port to Windows CNG
    return NULL;
}

char *pp_key_decrypted_from_pem(const char *pem, const char *passphrase) {
    // FIXME: #108, port to Windows CNG
    return NULL;
}
