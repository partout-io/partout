/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/conditionals.h"

#if PARTOUT_WINDOWS
#include <Windows.h>
#include <bcrypt.h>
#endif

#include <stdlib.h>
#include "portable/prng.h"

uint32_t pp_prng_rand(void) {
    uint32_t value;
    if (!pp_prng_do((uint8_t *)&value, sizeof(value))) {
        abort();
    }
    return value;
}

#if PARTOUT_APPLE

#include <Security/Security.h>

bool pp_prng_do(uint8_t *dst, size_t len) {
    return SecRandomCopyBytes(kSecRandomDefault, len, dst) == errSecSuccess;
}

#elif PARTOUT_WINDOWS

bool pp_prng_do(uint8_t *dst, size_t len) {
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
#if PARTOUT_ANDROID
    arc4random_buf(dst, len);
    return true;
#else
    return (int)getrandom(dst, len, 0) == (int)len;
#endif
}

#endif
