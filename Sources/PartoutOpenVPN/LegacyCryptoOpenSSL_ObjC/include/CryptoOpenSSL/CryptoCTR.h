/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>
#import "CryptoMacros.h"
#import "CryptoProtocols.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CryptoCTRError) {
    CryptoCTRErrorGeneric,
    CryptoCTRErrorHMAC
};

@interface CryptoCTR : NSObject <Encrypter, Decrypter>

- (nullable instancetype)initWithCipherName:(NSString *)cipherName
                                 digestName:(NSString *)digestName
                                  tagLength:(NSInteger)tagLength
                              payloadLength:(NSInteger)payloadLength
                                      error:(NSError **)error;

@property (nonatomic, copy) NSError * (^mappedError)(CryptoCTRError);

@end

NS_ASSUME_NONNULL_END
