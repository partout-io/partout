//
//  tls.h
//  Partout
//
//  Created by Davide De Rosa on 6/27/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

#pragma once

#include <stdbool.h>
#include <stdint.h>

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
} tls_error_code;

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
} tls_channel_options;

typedef struct {
    const tls_channel_options *_Nonnull opt;
    bool is_connected;
    SSL_CTX *_Nonnull ssl_ctx;
    SSL *_Nonnull ssl;
    BIO *_Nonnull bio_plain;
    BIO *_Nonnull bio_cipher_in;
    BIO *_Nonnull bio_cipher_out;
    uint8_t *_Nonnull buf_cipher;
    uint8_t *_Nonnull buf_plain;
    size_t buf_len;
} tls_channel_t;

tls_channel_options *_Nonnull tls_channel_options_create(int sec_level,
                                                         size_t buf_len,
                                                         bool eku,
                                                         bool san_host,
                                                         const char *_Nonnull ca_path,
                                                         const char *_Nullable cert_pem,
                                                         const char *_Nullable key_pem,
                                                         const char *_Nullable hostname,
                                                         void (*_Nonnull on_verify_failure)());

void tls_channel_options_free(tls_channel_options *_Nonnull opt);

tls_channel_t *_Nullable tls_channel_create(const tls_channel_options *_Nonnull opt,
                                            tls_error_code *_Nonnull error);
void tls_channel_free(tls_channel_t *_Nonnull tls);

bool tls_channel_start(tls_channel_t *_Nonnull tls);

zeroing_data_t *_Nullable tls_channel_pull_cipher(tls_channel_t *_Nonnull tls,
                                                  tls_error_code *_Nullable error);

zeroing_data_t *_Nullable tls_channel_pull_plain(tls_channel_t *_Nonnull tls,
                                                 tls_error_code *_Nullable error);

bool tls_channel_put_cipher(tls_channel_t *_Nonnull tls,
                            const uint8_t *_Nonnull src, size_t src_len,
                            tls_error_code *_Nullable error);

bool tls_channel_put_plain(tls_channel_t *_Nonnull tls,
                           const uint8_t *_Nonnull src, size_t src_len,
                           tls_error_code *_Nullable error);

char *_Nullable tls_channel_ca_md5(const tls_channel_t *_Nonnull tls);
