//
//  keys.h
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

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "crypto/zeroing_data.h"

bool key_init_seed(const zeroing_data_t *_Nonnull zd);

typedef struct {
    zeroing_data_t *_Nonnull dst;
    const char *_Nonnull digest_name;
    const zeroing_data_t *_Nonnull secret;
    const zeroing_data_t *_Nonnull data;
} key_hmac_ctx;

zeroing_data_t *_Nonnull key_hmac_create();
size_t key_hmac_do(key_hmac_ctx *_Nonnull ctx);

char *_Nullable key_decrypted_from_path(const char *_Nonnull path,
                                        const char *_Nonnull passphrase);

char *_Nullable key_decrypted_from_pem(const char *_Nonnull pem,
                                       const char *_Nonnull passphrase);
