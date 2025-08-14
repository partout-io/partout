// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import <Foundation/Foundation.h>

#import "CryptoAEAD+OpenVPN.h"
#import "Errors.h"
#import "PacketMacros.h"

@import _PartoutCryptoOpenSSL_ObjC;

@implementation CryptoAEAD (OpenVPN)

- (id<DataPathEncrypter>)dataPathEncrypter
{
    return [[DataPathCryptoAEAD alloc] initWithCrypto:self];
}

- (id<DataPathDecrypter>)dataPathDecrypter
{
    return [[DataPathCryptoAEAD alloc] initWithCrypto:self];
}

@end

@interface DataPathCryptoAEAD ()

@property (nonatomic, strong) CryptoAEAD *crypto;

@end

@implementation DataPathCryptoAEAD

- (instancetype)initWithCrypto:(CryptoAEAD *)crypto
{
    if ((self = [super init])) {
        self.crypto = crypto;
        self.peerId = OpenVPNPacketPeerIdDisabled;
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
    *packetLength = payload.length;
    if (!block) {
        memcpy(packetBytes, payload.bytes, payload.length);
        return;
    }

    NSInteger packetLengthOffset;
    block(packetBytes, &packetLengthOffset, payload);
    *packetLength += packetLengthOffset;
}

- (NSData *)encryptedDataPacketWithKey:(uint8_t)key packetId:(uint32_t)packetId packetBytes:(const uint8_t *)packetBytes packetLength:(NSInteger)packetLength error:(NSError *__autoreleasing *)error
{
    OPENVPN_DP_ENCRYPT_BEGIN(self.peerId)

    const int capacity = headerLength + OpenVPNPacketIdLength + (int)[self.crypto encryptionCapacityWithLength:packetLength];
    NSMutableData *encryptedPacket = [[NSMutableData alloc] initWithLength:capacity];
    uint8_t *ptr = encryptedPacket.mutableBytes;
    NSInteger encryptedPacketLength = INT_MAX;

    *(uint32_t *)(ptr + headerLength) = htonl(packetId);

    CryptoFlags flags;
    flags.iv = ptr + headerLength;
    flags.ivLength = OpenVPNPacketIdLength;
    if (hasPeerId) {
        PacketHeaderSetDataV2(ptr, key, self.peerId);
        flags.ad = ptr;
        flags.adLength = headerLength + OpenVPNPacketIdLength;
    }
    else {
        PacketHeaderSet(ptr, PacketCodeDataV1, key, nil);
        flags.ad = ptr + headerLength;
        flags.adLength = OpenVPNPacketIdLength;
    }

    const BOOL success = [self.crypto encryptBytes:packetBytes
                                            length:packetLength
                                              dest:(ptr + headerLength + OpenVPNPacketIdLength) // skip header and packet id
                                        destLength:&encryptedPacketLength
                                             flags:&flags
                                             error:error];

    NSAssert(encryptedPacketLength <= capacity, @"Did not allocate enough bytes for payload");

    if (!success) {
        return nil;
    }

    encryptedPacket.length = headerLength + OpenVPNPacketIdLength + encryptedPacketLength;
    return encryptedPacket;
}

#pragma mark DataPathDecrypter

- (BOOL)decryptDataPacket:(NSData *)packet into:(uint8_t *)packetBytes length:(NSInteger *)packetLength packetId:(uint32_t *)packetId error:(NSError *__autoreleasing *)error
{
    NSAssert(packet.length > 0, @"Decrypting an empty packet, how did it get this far?");

    OPENVPN_DP_DECRYPT_BEGIN(packet)
    if (packet.length < headerLength + OpenVPNPacketIdLength) {
        return NO;
    }

    CryptoFlags flags;
    flags.iv = packet.bytes + headerLength;
    flags.ivLength = OpenVPNPacketIdLength;
    if (hasPeerId) {
        if (peerId != self.peerId) {
            if (error) {
                *error = OpenVPNErrorWithCode(OpenVPNErrorCodeDataPathPeerIdMismatch);
            }
            return NO;
        }
        flags.ad = packet.bytes;
        flags.adLength = headerLength + OpenVPNPacketIdLength;
    }
    else {
        flags.ad = packet.bytes + headerLength;
        flags.adLength = OpenVPNPacketIdLength;
    }

    // skip header + packet id
    const BOOL success = [self.crypto decryptBytes:(packet.bytes + headerLength + OpenVPNPacketIdLength)
                                            length:(int)(packet.length - (headerLength + OpenVPNPacketIdLength))
                                              dest:packetBytes
                                        destLength:packetLength
                                             flags:&flags
                                             error:error];
    if (!success) {
        return NO;
    }
    *packetId = ntohl(*(const uint32_t *)(flags.iv));
    return YES;
}

- (NSData *)parsePayloadWithBlock:(DataPathParseBlock)block compressionHeader:(nonnull uint8_t *)compressionHeader packetBytes:(nonnull uint8_t *)packetBytes packetLength:(NSInteger)packetLength error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    uint8_t *payload = packetBytes;
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
