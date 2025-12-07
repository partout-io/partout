/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"
#include <stdlib.h>

#if defined(__APPLE__)

#include <Security/Security.h>

bool minif_prng_do(void *dst, size_t len) {
    return SecRandomCopyBytes(kSecRandomDefault, len, dst) == errSecSuccess;
}

#elif defined(_WIN32)

#include <windows.h>
#include <bcrypt.h>

bool minif_prng_do(void *dst, size_t len) {
    NTSTATUS status = BCryptGenRandom(
        NULL,
        dst,
        len,
        BCRYPT_USE_SYSTEM_PREFERRED_RNG
    );
    return BCRYPT_SUCCESS(status);
}

#else

#include <stdlib.h>
#include <sys/random.h>

bool minif_prng_do(void *dst, size_t len) {
#ifdef __ANDROID_API__
    arc4random_buf(dst, len);
    return true;
#else
    return (int)getrandom(dst, len, 0) == (int)len;
#endif
}

#endif
