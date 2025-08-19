// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import "CryptoOpenSSL/CryptoMacros.h"
#import "ControlPacket.h"

@implementation ControlPacket

- (instancetype)initWithCode:(PacketCode)code
                         key:(uint8_t)key
                   sessionId:(NSData *)sessionId
                    packetId:(uint32_t)packetId
                     payload:(nullable NSData *)payload
                      ackIds:(nullable NSArray<NSNumber *> *)ackIds
          ackRemoteSessionId:(nullable NSData *)ackRemoteSessionId
{
    NSCParameterAssert(sessionId.length == OpenVPNPacketSessionIdLength);
    
    if (!(self = [super init])) {
        return nil;
    }
    _code = code;
    _key = key;
    _sessionId = sessionId;
    _packetId = packetId;
    _payload = payload;
    _ackIds = ackIds;
    _ackRemoteSessionId = ackRemoteSessionId;

    return self;
}

- (instancetype)initWithKey:(uint8_t)key
                  sessionId:(NSData *)sessionId
                     ackIds:(NSArray<NSNumber *> *)ackIds
         ackRemoteSessionId:(NSData *)ackRemoteSessionId
{
    NSCParameterAssert(sessionId.length == OpenVPNPacketSessionIdLength);
    NSCParameterAssert(ackRemoteSessionId.length == OpenVPNPacketSessionIdLength);
    
    if (!(self = [super init])) {
        return nil;
    }
    _packetId = UINT32_MAX; // bogus marker
    _code = PacketCodeAckV1;
    _key = key;
    _sessionId = sessionId;
    _ackIds = ackIds;
    _ackRemoteSessionId = ackRemoteSessionId;
    
    return self;
}

- (BOOL)isAck
{
    return (self.packetId == UINT32_MAX);
}

- (NSInteger)rawCapacity
{
    const BOOL isAck = self.isAck;
    const NSUInteger ackLength = self.ackIds.count;
    NSCAssert(!isAck || ackLength > 0, @"Ack packet must provide positive ackLength");
    NSInteger n = OpenVPNPacketAckLengthLength;
    if (ackLength > 0) {
        n += ackLength * OpenVPNPacketIdLength + OpenVPNPacketSessionIdLength;
    }
    if (!isAck) {
        n += OpenVPNPacketIdLength;
    }
    n += self.payload.length;
    return n;
}

- (NSInteger)rawSerializeTo:(uint8_t *)to
{
    uint8_t *ptr = to;
    if (self.ackIds.count > 0) {
        NSCParameterAssert(self.ackRemoteSessionId.length == OpenVPNPacketSessionIdLength);
        *ptr = self.ackIds.count;
        ptr += OpenVPNPacketAckLengthLength;
        for (NSNumber *n in self.ackIds) {
            const uint32_t ackId = (uint32_t)n.unsignedIntegerValue;
            *(uint32_t *)ptr = CFSwapInt32HostToBig(ackId);
            ptr += OpenVPNPacketIdLength;
        }
        memcpy(ptr, self.ackRemoteSessionId.bytes, OpenVPNPacketSessionIdLength);
        ptr += OpenVPNPacketSessionIdLength;
    }
    else {
        *ptr = 0; // no acks
        ptr += OpenVPNPacketAckLengthLength;
    }
    if (self.code != PacketCodeAckV1) {
        *(uint32_t *)ptr = CFSwapInt32HostToBig(self.packetId);
        ptr += OpenVPNPacketIdLength;
        if (self.payload) {
            memcpy(ptr, self.payload.bytes, self.payload.length);
            ptr += self.payload.length;
        }
    }
    return ptr - to;
}

- (NSInteger)capacity
{
    return OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength + self.rawCapacity;
}

- (NSData *)serialized
{
    NSMutableData *data = [[NSMutableData alloc] initWithLength:self.capacity];
    uint8_t *ptr = data.mutableBytes;
    ptr += PacketHeaderSet(ptr, self.code, self.key, self.sessionId.bytes);
    [self rawSerializeTo:ptr];
    return data;
}

@end

@implementation ControlPacket (Authentication)

- (NSInteger)capacityWithAuthenticator:(id<Encrypter>)auth
{
    return auth.digestLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength + self.capacity;
}

- (BOOL)serializeTo:(uint8_t *)to authenticatingWith:(id<Encrypter>)auth replayId:(uint32_t)replayId timestamp:(uint32_t)timestamp error:(NSError *__autoreleasing  _Nullable *)error
{
    uint8_t *ptr = to + auth.digestLength;
    const uint8_t *subject = ptr;
    *(uint32_t *)ptr = CFSwapInt32HostToBig(replayId);
    ptr += OpenVPNPacketReplayIdLength;
    *(uint32_t *)ptr = CFSwapInt32HostToBig(timestamp);
    ptr += OpenVPNPacketReplayTimestampLength;
    ptr += PacketHeaderSet(ptr, self.code, self.key, self.sessionId.bytes);
    ptr += [self rawSerializeTo:ptr];
    
    const NSInteger subjectLength = ptr - subject;
    NSInteger totalLength;
    if (![auth encryptBytes:subject length:subjectLength dest:to destLength:&totalLength flags:NULL error:error]) {
        return NO;
    }
    NSCAssert(totalLength == auth.digestLength + subjectLength, @"Encrypted packet size != (Digest + Subject)");
    PacketSwap(to, auth.digestLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength, OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength);
    return YES;
}

- (NSData *)serializedWithAuthenticator:(id<Encrypter>)auth replayId:(uint32_t)replayId timestamp:(uint32_t)timestamp error:(NSError *__autoreleasing  _Nullable *)error
{
    NSMutableData *data = [[NSMutableData alloc] initWithLength:[self capacityWithAuthenticator:auth]];
    if (![self serializeTo:data.mutableBytes authenticatingWith:auth replayId:replayId timestamp:timestamp error:error]) {
        return nil;
    }
    return data;
}

@end

@implementation ControlPacket (Encryption)

- (NSInteger)capacityWithEncrypter:(id<Encrypter>)encrypter
{
    return OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength + [encrypter encryptionCapacityWithLength:self.capacity];
}
    
- (BOOL)serializeTo:(uint8_t *)to encryptingWith:(nonnull id<Encrypter>)encrypter replayId:(uint32_t)replayId timestamp:(uint32_t)timestamp length:(NSInteger *)length adLength:(NSInteger)adLength error:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    uint8_t *ptr = to;
    ptr += PacketHeaderSet(to, self.code, self.key, self.sessionId.bytes);
    *(uint32_t *)ptr = CFSwapInt32HostToBig(replayId);
    ptr += OpenVPNPacketReplayIdLength;
    *(uint32_t *)ptr = CFSwapInt32HostToBig(timestamp);
    ptr += OpenVPNPacketReplayTimestampLength;
    
    NSAssert2(ptr - to == adLength, @"Incorrect AD bytes (%ld != %ld)", ptr - to, (long)adLength);
    
    NSMutableData *msg = [[NSMutableData alloc] initWithLength:self.rawCapacity];
    [self rawSerializeTo:msg.mutableBytes];
    
    CryptoFlags flags;
    flags.ad = to;
    flags.adLength = adLength;
    NSInteger encryptedMsgLength;
    if (![encrypter encryptBytes:msg.bytes length:msg.length dest:(to + adLength) destLength:&encryptedMsgLength flags:&flags error:error]) {
        return NO;
    }
    *length = adLength + encryptedMsgLength;
    
    return YES;
}

- (NSData *)serializedWithEncrypter:(id<Encrypter>)encrypter replayId:(uint32_t)replayId timestamp:(uint32_t)timestamp adLength:(NSInteger)adLength error:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    NSMutableData *data = [[NSMutableData alloc] initWithLength:[self capacityWithEncrypter:encrypter]];
    NSInteger length;
    if (![self serializeTo:data.mutableBytes encryptingWith:encrypter replayId:replayId timestamp:timestamp length:&length adLength:adLength error:error]) {
        return nil;
    }
    data.length = length;
    return data;
}

@end
