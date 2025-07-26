/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/prng.h"

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
