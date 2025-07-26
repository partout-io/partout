/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

#import "CryptoOpenSSL/CryptoMacros.h"
#import "DataPathCrypto.h"

NS_ASSUME_NONNULL_BEGIN

@protocol DataPathEncrypterProvider

- (id<DataPathEncrypter>)dataPathEncrypter;

@end

@protocol DataPathDecrypterProvider

- (id<DataPathDecrypter>)dataPathDecrypter;

@end

@protocol CryptoProvider

// encrypt/decrypt are mutually thread-safe
- (id<Encrypter, DataPathEncrypterProvider>)encrypter;
- (id<Decrypter, DataPathDecrypterProvider>)decrypter;

@end

NS_ASSUME_NONNULL_END
