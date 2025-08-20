/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

#import "PacketMacros.h"

NS_ASSUME_NONNULL_BEGIN

@protocol Encrypter;

@interface ControlPacket : NSObject<PacketProtocol>

- (instancetype)initWithCode:(PacketCode)code
                         key:(uint8_t)key
                   sessionId:(NSData *)sessionId
                    packetId:(uint32_t)packetId
                     payload:(nullable NSData *)payload
                      ackIds:(nullable NSArray<NSNumber *> *)ackIds
          ackRemoteSessionId:(nullable NSData *)ackRemoteSessionId;

- (instancetype)initWithKey:(uint8_t)key
                  sessionId:(NSData *)sessionId
                     ackIds:(NSArray<NSNumber *> *)ackIds
         ackRemoteSessionId:(NSData *)ackRemoteSessionId;

@property (nonatomic, assign, readonly) PacketCode code;
@property (nonatomic, assign, readonly) BOOL isAck;
@property (nonatomic, assign, readonly) uint8_t key;
@property (nonatomic, strong, readonly) NSData *sessionId;
@property (nonatomic, strong, readonly) NSArray<NSNumber *> *_Nullable ackIds; // uint32_t
@property (nonatomic, strong, readonly) NSData *_Nullable ackRemoteSessionId;
@property (nonatomic, assign, readonly) uint32_t packetId;
@property (nonatomic, strong, readonly) NSData *_Nullable payload;

- (NSData *)serialized;

@end

@interface ControlPacket (Authentication)

- (nullable NSData *)serializedWithAuthenticator:(id<Encrypter>)auth replayId:(uint32_t)replayId timestamp:(uint32_t)timestamp error:(NSError * _Nullable __autoreleasing *)error;

@end

@interface ControlPacket (Encryption)

- (nullable NSData *)serializedWithEncrypter:(id<Encrypter>)encrypter replayId:(uint32_t)replayId timestamp:(uint32_t)timestamp adLength:(NSInteger)adLength error:(NSError * _Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
