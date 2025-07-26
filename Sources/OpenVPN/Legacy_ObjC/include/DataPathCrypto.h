/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define DP_ENCRYPT_BEGIN(peerId) \
    const BOOL hasPeerId = (peerId != PacketPeerIdDisabled); \
    int headerLength = PacketOpcodeLength; \
    if (hasPeerId) { \
        headerLength += PacketPeerIdLength; \
    }

#define DP_DECRYPT_BEGIN(packet) \
    const uint8_t *ptr = packet.bytes; \
    PacketCode code; \
    PacketOpcodeGet(ptr, &code, NULL); \
    uint32_t peerId = PacketPeerIdDisabled; \
    const BOOL hasPeerId = (code == PacketCodeDataV2); \
    int headerLength = PacketOpcodeLength; \
    if (hasPeerId) { \
        headerLength += PacketPeerIdLength; \
        if (packet.length < headerLength) { \
            return NO; \
        } \
        peerId = PacketHeaderGetDataV2PeerId(ptr); \
    }

typedef void (^DataPathAssembleBlock)(uint8_t *packetDest, NSInteger *packetLengthOffset, NSData *payload);
typedef BOOL (^DataPathParseBlock)(uint8_t *payload,
                                   NSInteger *payloadOffset,
                                   uint8_t *header,
                                   NSInteger *headerLength,
                                   const uint8_t *packet,
                                   NSInteger packetLength,
                                   NSError **error);

@protocol DataPathChannel

- (uint32_t)peerId;
- (void)setPeerId:(uint32_t)peerId;
- (NSInteger)encryptionCapacityWithLength:(NSInteger)length;

@end

@protocol DataPathEncrypter <DataPathChannel>

- (void)assembleDataPacketWithBlock:(nullable DataPathAssembleBlock)block packetId:(uint32_t)packetId payload:(NSData *)payload into:(uint8_t *)packetBytes length:(NSInteger *)packetLength;
- (nullable NSData *)encryptedDataPacketWithKey:(uint8_t)key packetId:(uint32_t)packetId packetBytes:(const uint8_t *)packetBytes packetLength:(NSInteger)packetLength error:(NSError **)error;

@end

@protocol DataPathDecrypter <DataPathChannel>

- (BOOL)decryptDataPacket:(NSData *)packet into:(uint8_t *)packetBytes length:(NSInteger *)packetLength packetId:(uint32_t *)packetId error:(NSError **)error;
- (nullable NSData *)parsePayloadWithBlock:(nullable DataPathParseBlock)block compressionHeader:(uint8_t *)compressionHeader packetBytes:(uint8_t *)packetBytes packetLength:(NSInteger)packetLength error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
