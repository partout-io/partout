/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "tls/tls.h"

// FIXME: #108, implement with mbedTLS

//static const char *const TLSBoxClientEKU = "TLS Web Client Authentication";
static const char *const TLSBoxServerEKU = "TLS Web Server Authentication";

pp_tls_ctx pp_tls_create(const pp_tls_options *opt, pp_tls_error_code *error) {
    return NULL;
}

void pp_tls_free(pp_tls_ctx tls) {
}

bool pp_tls_start(pp_tls_ctx _Nonnull tls) {
    return false;
}

bool pp_tls_is_connected(pp_tls_ctx _Nonnull tls) {
    return false;
}

// MARK: - I/O

pp_zd *_Nullable pp_tls_pull_cipher(pp_tls_ctx _Nonnull tls,
                                                  pp_tls_error_code *_Nullable error) {
    return NULL;
}

pp_zd *_Nullable pp_tls_pull_plain(pp_tls_ctx _Nonnull tls,
                                                 pp_tls_error_code *_Nullable error) {
    return NULL;
}

bool pp_tls_put_cipher(pp_tls_ctx _Nonnull tls,
                            const uint8_t *_Nonnull src, size_t src_len,
                            pp_tls_error_code *_Nullable error) {
    return false;
}

bool pp_tls_put_plain(pp_tls_ctx _Nonnull tls,
                           const uint8_t *_Nonnull src, size_t src_len,
                           pp_tls_error_code *_Nullable error) {
    return false;
}

// MARK: - MD5

char *pp_tls_ca_md5(const pp_tls_ctx tls) {
    return NULL;
}
