// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import <Foundation/Foundation.h>

#import "CryptoCBC+OpenVPN.h"
#import "CryptoOpenSSL/CryptoMacros.h"
#import "Errors.h"
#import "PacketMacros.h"

@import _PartoutCryptoOpenSSL_ObjC;

@implementation CryptoCBC (OpenVPN)

- (id<DataPathEncrypter>)dataPathEncrypter
{
    return [[DataPathCryptoCBC alloc] initWithCrypto:self];
}

- (id<DataPathDecrypter>)dataPathDecrypter
{
    return [[DataPathCryptoCBC alloc] initWithCrypto:self];
}

@end

@interface DataPathCryptoCBC ()

@property (nonatomic, strong) CryptoCBC *crypto;

@end

@implementation DataPathCryptoCBC

- (instancetype)initWithCrypto:(CryptoCBC *)crypto
{
    if ((self = [super init])) {
        self.crypto = crypto;
        self.peerId = PacketPeerIdDisabled;
    }
    return self;
}

#pragma mark DataPathChannel

- (void)setPeerId:(uint32_t)peerId
{
    _peerId = peerId & 0xffffff;
}

- (NSInteger)encryptionCapacityWithLength:(NSInteger)length
{
    return [self.crypto encryptionCapacityWithLength:length];
}

#pragma mark DataPathEncrypter

- (void)assembleDataPacketWithBlock:(DataPathAssembleBlock)block packetId:(uint32_t)packetId payload:(NSData *)payload into:(uint8_t *)packetBytes length:(NSInteger *)packetLength
{
    uint8_t *ptr = packetBytes;
    *(uint32_t *)ptr = htonl(packetId);
    ptr += sizeof(uint32_t);
    *packetLength = (int)(ptr - packetBytes + payload.length);
    if (!block) {
        memcpy(ptr, payload.bytes, payload.length);
        return;
    }

    NSInteger packetLengthOffset;
    block(ptr, &packetLengthOffset, payload);
    *packetLength += packetLengthOffset;
}

- (NSData *)encryptedDataPacketWithKey:(uint8_t)key packetId:(uint32_t)packetId packetBytes:(const uint8_t *)packetBytes packetLength:(NSInteger)packetLength error:(NSError *__autoreleasing *)error
{
    DP_ENCRYPT_BEGIN(self.peerId)

    const int capacity = headerLength + (int)[self.crypto encryptionCapacityWithLength:packetLength];
    NSMutableData *encryptedPacket = [[NSMutableData alloc] initWithLength:capacity];
    uint8_t *ptr = encryptedPacket.mutableBytes;
    NSInteger encryptedPacketLength = INT_MAX;
    const BOOL success = [self.crypto encryptBytes:packetBytes
                                            length:packetLength
                                              dest:(ptr + headerLength) // skip header bytes
                                        destLength:&encryptedPacketLength
                                             flags:NULL
                                             error:error];

    NSAssert(encryptedPacketLength <= capacity, @"Did not allocate enough bytes for payload");

    if (!success) {
        return nil;
    }

    if (hasPeerId) {
        PacketHeaderSetDataV2(ptr, key, self.peerId);
    }
    else {
        PacketHeaderSet(ptr, PacketCodeDataV1, key, nil);
    }
    encryptedPacket.length = headerLength + encryptedPacketLength;
    return encryptedPacket;
}

#pragma mark DataPathDecrypter

- (BOOL)decryptDataPacket:(NSData *)packet into:(uint8_t *)packetBytes length:(NSInteger *)packetLength packetId:(uint32_t *)packetId error:(NSError *__autoreleasing *)error
{
    NSAssert(packet.length > 0, @"Decrypting an empty packet, how did it get this far?");

    DP_DECRYPT_BEGIN(packet)
    if (packet.length < headerLength + self.crypto.digestLength + self.crypto.cipherIVLength) {
        return NO;
    }

    // skip header = (code, key)
    const BOOL success = [self.crypto decryptBytes:(packet.bytes + headerLength)
                                            length:(int)(packet.length - headerLength)
                                              dest:packetBytes
                                        destLength:packetLength
                                             flags:NULL
                                             error:error];
    if (!success) {
        return NO;
    }
    if (hasPeerId) {
        if (peerId != self.peerId) {
            if (error) {
                *error = OpenVPNErrorWithCode(OpenVPNErrorCodeDataPathPeerIdMismatch);
            }
            return NO;
        }
    }
    *packetId = ntohl(*(uint32_t *)packetBytes);
    return YES;
}

- (NSData *)parsePayloadWithBlock:(DataPathParseBlock)block compressionHeader:(nonnull uint8_t *)compressionHeader packetBytes:(nonnull uint8_t *)packetBytes packetLength:(NSInteger)packetLength error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    uint8_t *payload = packetBytes;
    payload += sizeof(uint32_t); // packet id
    NSUInteger length = packetLength - (int)(payload - packetBytes);
    if (!block) {
        *compressionHeader = 0x00;
        return [NSData dataWithBytes:payload length:length];
    }

    NSInteger payloadOffset;
    NSInteger payloadHeaderLength;
    if (!block(payload, &payloadOffset, compressionHeader, &payloadHeaderLength, packetBytes, packetLength, error)) {
        return NULL;
    }
    length -= payloadHeaderLength;
    return [NSData dataWithBytes:(payload + payloadOffset) length:length];
}

@end
