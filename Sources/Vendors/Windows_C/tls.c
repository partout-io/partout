/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/allocation.h"
#include "crypto/tls.h"

// FIXME: #108, port to Windows Schannel or mbedTLS (would then move out of Windows_C)

//static const char *const TLSBoxClientEKU = "TLS Web Client Authentication";
static const char *const TLSBoxServerEKU = "TLS Web Server Authentication";

tls_channel_ctx tls_channel_create(const tls_channel_options *opt, tls_error_code *error) {
    return NULL;
}

void tls_channel_free(tls_channel_ctx tls) {
}

bool tls_channel_start(tls_channel_ctx _Nonnull tls) {
    return false;
}

bool tls_channel_is_connected(tls_channel_ctx _Nonnull tls) {
    return false;
}

// MARK: - I/O

zeroing_data_t *_Nullable tls_channel_pull_cipher(tls_channel_ctx _Nonnull tls,
                                                  tls_error_code *_Nullable error) {
    return NULL;
}

zeroing_data_t *_Nullable tls_channel_pull_plain(tls_channel_ctx _Nonnull tls,
                                                 tls_error_code *_Nullable error) {
    return NULL;
}

bool tls_channel_put_cipher(tls_channel_ctx _Nonnull tls,
                            const uint8_t *_Nonnull src, size_t src_len,
                            tls_error_code *_Nullable error) {
    return false;
}

bool tls_channel_put_plain(tls_channel_ctx _Nonnull tls,
                           const uint8_t *_Nonnull src, size_t src_len,
                           tls_error_code *_Nullable error) {
    return false;
}

// MARK: - MD5

char *tls_channel_ca_md5(const tls_channel_ctx tls) {
    return NULL;
}
