//
//  prng.c
//  Partout
//
//  Created by Davide De Rosa on 6/23/25.
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

#include "vendors/prng.h"

#ifdef __APPLE__
#include <Security/Security.h>

bool prng_do(uint8_t *dst, size_t len) {
    return SecRandomCopyBytes(kSecRandomDefault, len, dst) == errSecSuccess;
}
#else

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>

bool prng_do(uint8_t *_Nonnull dst, size_t len) {
    NTSTATUS status = BCryptGenRandom(
        NULL,
        dst,
        len,
        BCRYPT_USE_SYSTEM_PREFERRED_RNG
    );
    return BCRYPT_SUCCESS(status);
}
#else
#include <sys/random.h>

bool prng_do(uint8_t *dst, size_t len) {
    return (int)getrandom(dst, len, 0) == (int)len;
}
#endif

#endif
