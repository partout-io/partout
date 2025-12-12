/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdlib.h>
#include "portable/prng.h"

uint32_t pp_prng_rand() {
#ifdef _WIN32
    return rand();
#else
    return arc4random();
#endif
}

#if defined(__APPLE__)

#include <Security/Security.h>

bool pp_prng_do(uint8_t *dst, size_t len) {
    return SecRandomCopyBytes(kSecRandomDefault, len, dst) == errSecSuccess;
}

#elif defined(_WIN32)

#include <windows.h>
#include <bcrypt.h>

bool pp_prng_do(uint8_t *_Nonnull dst, size_t len) {
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

bool pp_prng_do(uint8_t *dst, size_t len) {
#ifdef __ANDROID__
    arc4random_buf(dst, len);
    return true;
#else
    return (int)getrandom(dst, len, 0) == (int)len;
#endif
}

#endif
