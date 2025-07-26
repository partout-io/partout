/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>
#import "CryptoMacros.h"
#import "CryptoProtocols.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CryptoCBCError) {
    CryptoCBCErrorGeneric,
    CryptoCBCErrorRandomGenerator,
    CryptoCBCErrorHMAC
};

@interface CryptoCBC : NSObject <Encrypter, Decrypter>

- (nullable instancetype)initWithCipherName:(nullable NSString *)cipherName
                                 digestName:(NSString *)digestName
                                      error:(NSError **)error;
- (int)cipherIVLength;

@property (nonatomic, copy) NSError * (^mappedError)(CryptoCBCError);

@end

NS_ASSUME_NONNULL_END
