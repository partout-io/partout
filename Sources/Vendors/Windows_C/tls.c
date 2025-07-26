//
//  tls.c
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

#include "crypto/allocation.h"
#include "crypto/tls.h"

// FIXME: #108, port to Windows Schannel

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
