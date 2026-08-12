/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"
#include <stdlib.h>

char *minif_strdup(const char *string) {
#ifdef _WIN32
    char *copy = _strdup(string);
#else
    char *copy = strdup(string);
#endif
    if (!copy) abort();
    return copy;
}

FILE *minif_fopen(const char *filename, const char *mode) {
#ifdef _WIN32
    FILE *file_ret = NULL;
    errno_t file_err = fopen_s(&file_ret, filename, mode);
    if (file_err != 0) return NULL;
    return file_ret;
#else
    return fopen(filename, mode);
#endif
}

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
#ifdef __ANDROID__
    arc4random_buf(dst, len);
    return true;
#else
    return (int)getrandom(dst, len, 0) == (int)len;
#endif
}

#endif
