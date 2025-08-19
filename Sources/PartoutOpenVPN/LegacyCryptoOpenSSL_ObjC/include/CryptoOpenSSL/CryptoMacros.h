/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

extern NSString *_Nonnull const PartoutCryptoErrorDomain;

#define CRYPTO_OPENSSL_SUCCESS(ret) (ret > 0)
#define CRYPTO_OPENSSL_TRACK_STATUS(ret) if (ret > 0) ret =
#define CRYPTO_OPENSSL_RETURN_STATUS(ret, raised)\
if (ret <= 0) {\
    if (error) {\
        *error = raised;\
    }\
    return NO;\
}\
return YES;

/// Custom flags for encryption routines.
typedef struct {

    /// A custom initialization vector (IV).
    const uint8_t *_Nullable iv;

    /// The length of ``iv``.
    NSInteger ivLength;

    /// A custom associated data for AEAD (AD).
    const uint8_t *_Nullable ad;

    /// The length of ``ad``.
    NSInteger adLength;

    /// Enable testable (predictable) behavior.
    BOOL forTesting;
} CryptoFlags;
