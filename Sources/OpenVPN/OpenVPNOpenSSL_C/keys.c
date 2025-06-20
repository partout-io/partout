//
//  keys.c
//  Partout
//
//  Created by Davide De Rosa on 6/20/25.
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

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include "keys.h"

#define KeyHMACMaxLength    100

zeroing_data_t *key_hmac_buf() {
    return zd_create(KeyHMACMaxLength);
}

size_t key_hmac(key_hmac_ctx *_Nonnull ctx) {
    assert(ctx->dst->length >= KeyHMACMaxLength);

    const EVP_MD *md = EVP_get_digestbyname(ctx->digest_name);
    unsigned int dst_len = 0;
    const bool success = HMAC(md,
                              ctx->secret->bytes,
                              (int)ctx->secret->length,
                              ctx->data->bytes,
                              ctx->data->length,
                              ctx->dst->bytes,
                              &dst_len) != NULL;
    if (!success) {
        return 0;
    }
    return dst_len;
}
