//
//  dp_mock.h
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

#pragma once

#include "crypto_mock.h"
#include "crypto_openssl/crypto_aead.h"
#include "crypto_openssl/crypto_cbc.h"
#include "dp_mode_ad.h"

static inline
dp_mode_t *_Nonnull dp_mode_ad_create_mock(compression_framing_t comp_f) {
    crypto_mock_t *mock = crypto_mock_create();
    return dp_mode_ad_create((crypto_t *)mock, (crypto_free_t)crypto_mock_free, comp_f);
}

static inline
dp_mode_t *_Nonnull dp_mode_ad_create_aead(const char *_Nonnull cipher,
                                           size_t tag_len, size_t id_len,
                                           compression_framing_t comp_f) {
    crypto_aead_t *crypto = crypto_aead_create(cipher, tag_len, id_len);
    return dp_mode_ad_create((crypto_t *)crypto, (crypto_free_t)crypto_aead_free, comp_f);
}

static inline
dp_mode_t *_Nonnull dp_mode_hmac_create_mock(compression_framing_t comp_f) {
    crypto_mock_t *mock = crypto_mock_create();
    return dp_mode_hmac_create((crypto_t *)mock, (crypto_free_t)crypto_mock_free, comp_f);
}

static inline
dp_mode_t *_Nonnull dp_mode_hmac_create_cbc(const char *_Nullable cipher,
                                            const char *_Nonnull digest,
                                            compression_framing_t comp_f) {
    crypto_cbc_t *crypto = crypto_cbc_create(cipher, digest);
    return dp_mode_hmac_create((crypto_t *)crypto, (crypto_free_t)crypto_cbc_free, comp_f);
}
