//
//  crypto_ctr.h
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
    const EVP_CIPHER *_Nonnull cipher;
    const EVP_MD *_Nonnull digest;
    char *_Nonnull utf_cipher_name;
    char *_Nonnull utf_digest_name;
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t hmac_key_len;

    size_t ns_tag_len;
    size_t payload_len;

    EVP_MAC *_Nonnull mac;
    OSSL_PARAM *_Nonnull mac_params;
    EVP_CIPHER_CTX *_Nonnull ctx_enc;
    EVP_CIPHER_CTX *_Nonnull ctx_dec;
    zeroing_data_t *_Nonnull hmac_key_enc;
    zeroing_data_t *_Nonnull hmac_key_dec;
    uint8_t *_Nonnull buffer_hmac;

    crypto_meta_t meta;
    crypto_encrypter_t encrypter;
    crypto_decrypter_t decrypter;
} crypto_ctr_t;

crypto_ctr_t *_Nullable crypto_ctr_create(const char *_Nonnull cipher_name,
                                          const char *_Nonnull digest_name,
                                          size_t tag_len, size_t payload_len);
void crypto_ctr_free(crypto_ctr_t *_Nonnull ctx);
