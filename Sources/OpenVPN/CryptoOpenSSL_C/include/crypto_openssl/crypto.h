//
//  crypto.h
//  Partout
//
//  Created by Davide De Rosa on 3/3/17.
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
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#pragma once

#include "zeroing_data.h"

#define CRYPTO_OPENSSL_SUCCESS(ret) (ret > 0)
#define CRYPTO_OPENSSL_TRACK_STATUS(ret) if (ret > 0) ret =
#define CRYPTO_OPENSSL_RETURN_STATUS(ret, raised)\
if (ret <= 0) {\
    if (error) {\
        *error = raised;\
    }\
    return false;\
}\
return true;

typedef enum {
    CryptoErrorGeneric,
    CryptoErrorPRNG,
    CryptoErrorHMAC
} crypto_error_t;

/// Custom flags for encryption routines.
typedef struct {

    /// A custom initialization vector (IV).
    const uint8_t *iv;

    /// The length of ``iv``.
    size_t iv_len;

    /// A custom associated data for AEAD (AD).
    const uint8_t *ad;

    /// The length of ``ad``.
    size_t ad_len;

    /// Enable testable (predictable) behavior.
    int for_testing;
} crypto_flags_t;

typedef void (*crypto_configure_t)(void *ctx,
                                   const zeroing_data_t *cipher_key,
                                   const zeroing_data_t *hmac_key);

typedef bool (*crypto_encrypt_t)(void *ctx,
                                 const uint8_t *in, size_t in_len,
                                 uint8_t *out, size_t *out_len,
                                 const crypto_flags_t *flags, crypto_error_t *error);

typedef bool (*crypto_decrypt_t)(void *ctx, const uint8_t *in, size_t in_len,
                                 uint8_t *out, size_t *out_len,
                                 const crypto_flags_t *flags, crypto_error_t *error);

typedef bool (*crypto_verify_t)(void *ctx, const uint8_t *in, size_t in_len,
                                crypto_error_t *error);

typedef struct {
    crypto_configure_t configure;
    crypto_encrypt_t encrypt;
} crypto_encrypter_t;

typedef struct {
    crypto_configure_t configure;
    crypto_decrypt_t decrypt;
    crypto_verify_t verify;
} crypto_decrypter_t;

typedef size_t (*crypto_capacity_t)(const void *ctx, size_t len);

typedef struct {
    size_t digest_length;
    size_t tag_length;
    crypto_capacity_t encryption_capacity;
} crypto_meta_t;

#ifndef MAX
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#endif

#ifndef MIN
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif
