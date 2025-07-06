//
//  keys.c
//  Partout
//
//  Created by Davide De Rosa on 7/3/25.
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
#include "crypto/keys.h"

// FIXME: #101, port to Windows CNG

#define KeyHMACMaxLength    (size_t)128

bool key_init_seed(const zeroing_data_t *seed) {
    return true;
}

zeroing_data_t *key_hmac_create() {
    return zd_create(KeyHMACMaxLength);
}

size_t key_hmac_do(key_hmac_ctx *ctx) {
    return 0;
}

// MARK: -

char *key_decrypted_from_path(const char *path, const char *passphrase) {
    return NULL;
}

char *key_decrypted_from_pem(const char *pem, const char *passphrase) {
    return NULL;
}
