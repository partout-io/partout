/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "crypto/zeroing_data.h"

typedef enum {
    TLSErrorNone,
    TLSErrorCARead,
    TLSErrorCAUse,
    TLSErrorCAPeerVerification,
    TLSErrorClientCertificateRead,
    TLSErrorClientCertificateUse,
    TLSErrorClientKeyRead,
    TLSErrorClientKeyUse,
    TLSErrorHandshake,
    TLSErrorServerEKU,
    TLSErrorServerHost
} pp_tls_error_code;

typedef struct {
    int sec_level;
    size_t buf_len;
    bool eku;
    bool san_host;
    const char *_Nonnull ca_path;
    const char *_Nullable cert_pem;
    const char *_Nullable key_pem;
    const char *_Nullable hostname;
    void (*_Nonnull on_verify_failure)();
} pp_tls_channel_options;

typedef struct pp_tls_channel_t pp_tls_channel_t;
typedef struct pp_tls_channel_t *pp_tls_channel_ctx;

pp_tls_channel_options *_Nonnull pp_tls_channel_options_create(int sec_level,
                                                         size_t buf_len,
                                                         bool eku,
                                                         bool san_host,
                                                         const char *_Nonnull ca_path,
                                                         const char *_Nullable cert_pem,
                                                         const char *_Nullable key_pem,
                                                         const char *_Nullable hostname,
                                                         void (*_Nonnull on_verify_failure)());

void pp_tls_channel_options_free(pp_tls_channel_options *_Nonnull opt);

// "opt" ownership is transferred and released on free
pp_tls_channel_ctx _Nullable pp_tls_channel_create(const pp_tls_channel_options *_Nonnull opt,
                                            pp_tls_error_code *_Nonnull error);
void pp_tls_channel_free(pp_tls_channel_ctx _Nonnull tls);

bool pp_tls_channel_start(pp_tls_channel_ctx _Nonnull tls);
bool pp_tls_channel_is_connected(pp_tls_channel_ctx _Nonnull tls);

pp_zd *_Nullable pp_tls_channel_pull_cipher(pp_tls_channel_ctx _Nonnull tls,
                                                  pp_tls_error_code *_Nullable error);

pp_zd *_Nullable pp_tls_channel_pull_plain(pp_tls_channel_ctx _Nonnull tls,
                                                 pp_tls_error_code *_Nullable error);

bool pp_tls_channel_put_cipher(pp_tls_channel_ctx _Nonnull tls,
                            const uint8_t *_Nonnull src, size_t src_len,
                            pp_tls_error_code *_Nullable error);

bool pp_tls_channel_put_plain(pp_tls_channel_ctx _Nonnull tls,
                           const uint8_t *_Nonnull src, size_t src_len,
                           pp_tls_error_code *_Nullable error);

char *_Nullable pp_tls_channel_ca_md5(const pp_tls_channel_ctx _Nonnull tls);
