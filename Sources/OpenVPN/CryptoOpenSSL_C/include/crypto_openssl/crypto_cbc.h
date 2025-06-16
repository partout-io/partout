//
//  crypto_cbc.h
//  Partout
//
//  Created by Davide De Rosa on 6/14/25.
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

#include <openssl/evp.h>
#include "crypto.h"
#include "zeroing_data.h"

typedef struct {
    const EVP_CIPHER *cipher;
    const EVP_MD *digest;
    char *utf_cipher_name;
    char *utf_digest_name;
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t hmac_key_len;
    size_t digest_len;

    EVP_MAC *mac;
    OSSL_PARAM *mac_params;
    EVP_CIPHER_CTX *ctx_enc;
    EVP_CIPHER_CTX *ctx_dec;
    zeroing_data_t *hmac_key_enc;
    zeroing_data_t *hmac_key_dec;
    uint8_t *buffer_hmac;

    crypto_meta_t meta;
    crypto_encrypter_t encrypter;
    crypto_decrypter_t decrypter;
} crypto_cbc_t;

crypto_cbc_t *crypto_cbc_create(const char *cipher_name, const char *digest_name);
void crypto_cbc_free(crypto_cbc_t *ctx);
