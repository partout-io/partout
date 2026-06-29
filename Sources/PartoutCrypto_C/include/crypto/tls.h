/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "portable/zd.h"

#pragma clang assume_nonnull begin

typedef enum {
    PPTLSErrorNone,
    PPTLSErrorCARead,
    PPTLSErrorCAUse,
    PPTLSErrorCAPeerVerification,
    PPTLSErrorClientCertificateRead,
    PPTLSErrorClientCertificateUse,
    PPTLSErrorClientKeyRead,
    PPTLSErrorClientKeyUse,
    PPTLSErrorHandshake,
    PPTLSErrorServerEKU,
    PPTLSErrorServerHost
} pp_tls_error_code;

typedef struct {
    int sec_level;
    size_t buf_len;
    bool eku;
    bool san_host;
    const char *ca_path;
    const char *_Nullable cert_pem;
    const char *_Nullable key_pem;
    const char *_Nullable hostname;
    void *_Nullable ctx;
    void (*on_verify_failure)(void *_Nullable ctx);
} pp_tls_options;

pp_tls_options *pp_tls_options_create(int sec_level,
                                      size_t buf_len,
                                      bool eku,
                                      bool san_host,
                                      const char *ca_path,
                                      const char *_Nullable cert_pem,
                                      const char *_Nullable key_pem,
                                      const char *_Nullable hostname,
                                      void (*on_verify_failure)(void *_Nullable ctx),
                                      void *_Nullable ctx);

void pp_tls_options_free(pp_tls_options *opt);

/* Function table. */

typedef struct __pp_tls_struct *pp_tls;

typedef pp_tls _Nullable (*pp_tls_create_fn)(const pp_tls_options *opt,
                                             pp_tls_error_code *error);
typedef void (*pp_tls_free_fn)(pp_tls tls);
typedef bool (*pp_tls_start_fn)(pp_tls tls);
typedef bool (*pp_tls_is_connected_fn)(pp_tls tls);

typedef pp_zd *_Nullable (*pp_tls_pull_cipher_fn)(pp_tls tls,
                                                  pp_tls_error_code *_Nullable error);
typedef pp_zd *_Nullable (*pp_tls_pull_plain_fn)(pp_tls tls,
                                                 pp_tls_error_code *_Nullable error);

typedef bool (*pp_tls_put_cipher_fn)(pp_tls tls,
                                     const uint8_t *src,
                                     size_t src_len,
                                     pp_tls_error_code *_Nullable error);

typedef bool (*pp_tls_put_plain_fn)(pp_tls tls,
                                    const uint8_t *src,
                                    size_t src_len,
                                    pp_tls_error_code *_Nullable error);

typedef char *_Nullable (*pp_tls_ca_md5_fn)(const pp_tls tls);

#pragma clang assume_nonnull end
