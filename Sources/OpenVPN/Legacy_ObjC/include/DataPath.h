/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

@protocol DataPathEncrypter;
@protocol DataPathDecrypter;

#import "CompressionAlgorithm.h"
#import "CompressionFraming.h"
#import "DataPathCrypto.h"

NS_ASSUME_NONNULL_BEGIN

// send/receive should be mutually thread-safe

@interface DataPath : NSObject

@property (nonatomic, assign) uint32_t maxPacketId;

- (instancetype)initWithEncrypter:(id<DataPathEncrypter>)encrypter
                        decrypter:(id<DataPathDecrypter>)decrypter
                           peerId:(uint32_t)peerId // 24-bit, discard most significant byte
               compressionFraming:(CompressionFraming)compressionFraming
             compressionAlgorithm:(CompressionAlgorithm)compressionAlgorithm
                       maxPackets:(NSInteger)maxPackets
             usesReplayProtection:(BOOL)usesReplayProtection;

- (nullable NSArray<NSData *> *)encryptPackets:(NSArray<NSData *> *)packets key:(uint8_t)key error:(NSError **)error;
- (nullable NSArray<NSData *> *)decryptPackets:(NSArray<NSData *> *)packets keepAlive:(nullable bool *)keepAlive error:(NSError **)error;

// MARK: Testing

- (id<DataPathEncrypter>)encrypter;
- (id<DataPathDecrypter>)decrypter;
- (DataPathAssembleBlock)assemblePayloadBlock;
- (DataPathParseBlock)parsePayloadBlock;

@end

NS_ASSUME_NONNULL_END
