//
//  macros.h
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

#pragma once

#define CRYPTO_ASSERT(status) pp_assert(BCRYPT_SUCCESS(status));

#define CRYPTO_CHECK_CREATE(status) if (!BCRYPT_SUCCESS(status)) goto failure;

#define CRYPTO_CHECK(status)\
if (!BCRYPT_SUCCESS(status)) {\
    if (error) *error = CryptoErrorEncryption;\
    return 0;\
}

#define CRYPTO_CHECK_MAC(status)\
if (!BCRYPT_SUCCESS(status)) {\
    if (error) *error = CryptoErrorHMAC;\
    if (hHmac) BCryptDestroyHash(hHmac);\
    return 0;\
}

#define CRYPTO_CHECK_MAC_ALG(status)\
if (!BCRYPT_SUCCESS(status)) {\
    if (error) *error = CryptoErrorHMAC;\
    if (hHmac) BCryptDestroyHash(hHmac);\
    if (hAlgHmac) BCryptCloseAlgorithmProvider(hAlgHmac, 0);\
    return 0;\
}
