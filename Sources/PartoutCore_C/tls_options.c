/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "tls/tls.h"

pp_tls_options *_Nonnull pp_tls_options_create(int sec_level,
                                               size_t buf_len,
                                               bool eku,
                                               bool san_host,
                                               const char *_Nonnull ca_path,
                                               const char *_Nullable cert_pem,
                                               const char *_Nullable key_pem,
                                               const char *_Nullable hostname,
                                               void *ctx,
                                               void (*_Nonnull on_verify_failure)(void *ctx)) {

    pp_assert(ca_path && on_verify_failure);

    pp_tls_options *opt = pp_alloc(sizeof(pp_tls_options));
    opt->sec_level = sec_level;
    opt->buf_len = buf_len;
    opt->eku = eku;
    opt->san_host = san_host;
    opt->ca_path = pp_dup(ca_path);
    opt->cert_pem = cert_pem ? pp_dup(cert_pem) : NULL;
    opt->key_pem = key_pem ? pp_dup(key_pem) : NULL;
    opt->hostname = hostname ? pp_dup(hostname) : NULL;
    opt->ctx = ctx;
    opt->on_verify_failure = on_verify_failure;
    return opt;
}

void pp_tls_options_free(pp_tls_options *_Nonnull opt) {
    pp_free((char *)opt->ca_path);
    pp_free((char *)opt->cert_pem);
    pp_free((char *)opt->key_pem);
    pp_free((char *)opt->hostname);
    pp_free(opt);
}
