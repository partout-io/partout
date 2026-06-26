/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "tls/tls_base.h"

// FIXME: #108, Implement with mbedTLS

//static const char *const TLSBoxClientEKU = "TLS Web Client Authentication";
//static const char *const TLSBoxServerEKU = "TLS Web Server Authentication";

pp_tls pp_tls_create(const pp_tls_options *opt, pp_tls_error_code *error) {
    (void)opt;
    (void)error;
    return NULL;
}

void pp_tls_free(pp_tls tls) {
    (void)tls;
}

bool pp_tls_start(pp_tls tls) {
    (void)tls;
    return false;
}

bool pp_tls_is_connected(pp_tls tls) {
    (void)tls;
    return false;
}

// MARK: - I/O

pp_zd *_Nullable pp_tls_pull_cipher(pp_tls tls, pp_tls_error_code *_Nullable error) {
    (void)tls;
    (void)error;
    return NULL;
}

pp_zd *_Nullable pp_tls_pull_plain(pp_tls tls, pp_tls_error_code *_Nullable error) {
    (void)tls;
    (void)error;
    return NULL;
}

bool pp_tls_put_cipher(pp_tls tls,
                       const uint8_t *src, size_t src_len,
                       pp_tls_error_code *_Nullable error) {
    (void)tls;
    (void)src;
    (void)src_len;
    (void)error;
    return false;
}

bool pp_tls_put_plain(pp_tls tls,
                      const uint8_t *src, size_t src_len,
                      pp_tls_error_code *_Nullable error) {
    (void)tls;
    (void)src;
    (void)src_len;
    (void)error;
    return false;
}

// MARK: - MD5

char *pp_tls_ca_md5(const pp_tls tls) {
    (void)tls;
    return NULL;
}
