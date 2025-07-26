/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>
#import "CryptoMacros.h"
#import "CryptoProtocols.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CryptoAEADError) {
    CryptoAEADErrorGeneric
};

@interface CryptoAEAD : NSObject <Encrypter, Decrypter>

- (nullable instancetype)initWithCipherName:(NSString *)cipherName
                                  tagLength:(NSInteger)tagLength
                                   idLength:(NSInteger)idLength
                                      error:(NSError **)error;

@property (nonatomic, copy) NSError * (^mappedError)(CryptoAEADError);

@end

NS_ASSUME_NONNULL_END
