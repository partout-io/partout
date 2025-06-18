//
//  crypto_mock.c
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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

#include "dp_mode_macros.h"
#include "test/crypto_mock.h"

static inline
void reverse(uint8_t *dst, const uint8_t *src, size_t len) {
    for (size_t i = 0; i < len; i++) {
        dst[i] = src[len - 1 - i];
    }
}

size_t mock_capacity(const void *vctx, size_t len) {
    return 10 * len; // be ridiculously safe
}

static
void mock_configure_encrypt(void *vctx,
                            const zeroing_data_t *cipher_key,
                            const zeroing_data_t *hmac_key) {
    DP_LOG("crypto_mock_configure_encrypt");
}

// in -> aabb(reversed)ccdd
static
bool mock_encrypt(void *vctx,
                  uint8_t *out, size_t *out_len,
                  const uint8_t *in, size_t in_len,
                  const crypto_flags_t *flags, crypto_error_code *error) {
    DP_LOG("crypto_mock_encrypt");
    out[0] = 0xaa;
    out[1] = 0xbb;
    reverse(out + 2, in, in_len);
    out[2 + in_len] = 0xcc;
    out[2 + in_len + 1] = 0xdd;
    *out_len = in_len + 4;
    return true;
}

static
void mock_configure_decrypt(void *vctx,
                            const zeroing_data_t *cipher_key,
                            const zeroing_data_t *hmac_key) {
    DP_LOG("crypto_mock_configure_decrypt");
}

// in -> reversed
static
bool mock_decrypt(void *vctx,
                  uint8_t *out, size_t *out_len,
                  const uint8_t *in, size_t in_len,
                  const crypto_flags_t *flags, crypto_error_code *error) {
    DP_LOG("crypto_mock_decrypt");
    *out_len = in_len - 4;
    assert(in[0] == 0xaa);
    assert(in[1] == 0xbb);
    reverse(out, in + 2, *out_len);
    assert(in[2 + *out_len] == 0xcc);
    assert(in[2 + *out_len + 1] == 0xdd);
    return true;
}

static
bool mock_verify(void *vctx, const uint8_t *in, size_t in_len, crypto_error_code *error) {
    DP_LOG("crypto_mock_verify");
    return true;
}

// MARK: -

crypto_mock_t *crypto_mock_create() {
    DP_LOG("crypto_mock_create");
    crypto_mock_t *ctx = pp_alloc_crypto(sizeof(crypto_mock_t));
    ctx->crypto.encrypter.configure = mock_configure_encrypt;
    ctx->crypto.encrypter.encrypt = mock_encrypt;
    ctx->crypto.decrypter.configure = mock_configure_decrypt;
    ctx->crypto.decrypter.decrypt = mock_decrypt;
    ctx->crypto.decrypter.verify = mock_verify;
    ctx->crypto.meta.cipher_iv_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = 0;
    ctx->crypto.meta.encryption_capacity = mock_capacity;
    return ctx;
}

void crypto_mock_free(crypto_mock_t *ctx) {
    DP_LOG("crypto_mock_free");
    free(ctx);
}
