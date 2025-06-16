//
//  crypto_aead.h
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
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t tag_len;
    size_t id_len;

    EVP_CIPHER_CTX *_Nonnull ctx_enc;
    EVP_CIPHER_CTX *_Nonnull ctx_dec;
    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;

    crypto_meta_t meta;
    crypto_encrypter_t encrypter;
    crypto_decrypter_t decrypter;
} crypto_aead_t;

crypto_aead_t *_Nullable crypto_aead_create(const char *_Nonnull cipher_name,
                                            size_t tag_len, size_t id_len);
void crypto_aead_free(crypto_aead_t *_Nonnull ctx);
