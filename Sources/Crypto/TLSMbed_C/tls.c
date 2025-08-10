/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/allocation.h"
#include "crypto/tls.h"

// FIXME: #108, implement with mbedTLS

//static const char *const TLSBoxClientEKU = "TLS Web Client Authentication";
static const char *const TLSBoxServerEKU = "TLS Web Server Authentication";

pp_tls_channel_ctx pp_tls_channel_create(const pp_tls_channel_options *opt, pp_tls_error_code *error) {
    return NULL;
}

void pp_tls_channel_free(pp_tls_channel_ctx tls) {
}

bool pp_tls_channel_start(pp_tls_channel_ctx _Nonnull tls) {
    return false;
}

bool pp_tls_channel_is_connected(pp_tls_channel_ctx _Nonnull tls) {
    return false;
}

// MARK: - I/O

pp_zd *_Nullable pp_tls_channel_pull_cipher(pp_tls_channel_ctx _Nonnull tls,
                                                  pp_tls_error_code *_Nullable error) {
    return NULL;
}

pp_zd *_Nullable pp_tls_channel_pull_plain(pp_tls_channel_ctx _Nonnull tls,
                                                 pp_tls_error_code *_Nullable error) {
    return NULL;
}

bool pp_tls_channel_put_cipher(pp_tls_channel_ctx _Nonnull tls,
                            const uint8_t *_Nonnull src, size_t src_len,
                            pp_tls_error_code *_Nullable error) {
    return false;
}

bool pp_tls_channel_put_plain(pp_tls_channel_ctx _Nonnull tls,
                           const uint8_t *_Nonnull src, size_t src_len,
                           pp_tls_error_code *_Nullable error) {
    return false;
}

// MARK: - MD5

char *pp_tls_channel_ca_md5(const pp_tls_channel_ctx tls) {
    return NULL;
}
