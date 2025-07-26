/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

#import "CryptoProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface OpenVPNCryptoOptions : NSObject

- (instancetype)initWithCipherAlgorithm:(nullable NSString *)cipherAlgorithm
                        digestAlgorithm:(nullable NSString *)digestAlgorithm
                           cipherEncKey:(nullable ZeroingData *)cipherEncKey
                           cipherDecKey:(nullable ZeroingData *)cipherDecKey
                             hmacEncKey:(nullable ZeroingData *)hmacEncKey
                             hmacDecKey:(nullable ZeroingData *)hmacDecKey;

- (nullable NSString *)cipherAlgorithm;
- (nullable NSString *)digestAlgorithm;
- (nullable ZeroingData *)cipherEncKey;
- (nullable ZeroingData *)cipherDecKey;
- (nullable ZeroingData *)hmacEncKey;
- (nullable ZeroingData *)hmacDecKey;

@end

@protocol OpenVPNCryptoProtocol <CryptoProvider>

#pragma mark Initialization

- (BOOL)configureWithOptions:(OpenVPNCryptoOptions *)options error:(NSError **)error;
- (nullable OpenVPNCryptoOptions *)options;

#pragma mark Metadata

- (NSString *)version;
- (NSInteger)digestLength;
- (NSInteger)tagLength;

#pragma mark Helpers

// WARNING: hmac must be able to hold HMAC result
- (BOOL)hmacWithDigestName:(NSString *)digestName
                    secret:(const uint8_t *)secret
              secretLength:(NSInteger)secretLength
                      data:(const uint8_t *)data
                dataLength:(NSInteger)dataLength
                      hmac:(uint8_t *)hmac
                hmacLength:(NSInteger *)hmacLength
                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
