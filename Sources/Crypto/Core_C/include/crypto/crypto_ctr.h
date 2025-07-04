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

#include "crypto.h"
#include "crypto/zeroing_data.h"

crypto_ctx _Nullable crypto_ctr_create(const char *_Nonnull cipher_name,
                                       const char *_Nonnull digest_name,
                                       size_t tag_len, size_t payload_len,
                                       const crypto_keys_t *_Nullable keys);
void crypto_ctr_free(crypto_ctx _Nonnull ctx);
