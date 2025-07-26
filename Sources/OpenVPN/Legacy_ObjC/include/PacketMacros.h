/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define PacketOpcodeLength          ((NSInteger)1)
#define PacketIdLength              ((NSInteger)4)
#define PacketSessionIdLength       ((NSInteger)8)
#define PacketAckLengthLength       ((NSInteger)1)
#define PacketPeerIdLength          ((NSInteger)3)
#define PacketPeerIdDisabled        ((uint32_t)0xffffffu)
#define PacketReplayIdLength        ((NSInteger)4)
#define PacketReplayTimestampLength ((NSInteger)4)

typedef NS_ENUM(uint8_t, PacketCode) {
    PacketCodeSoftResetV1           = 0x03,
    PacketCodeControlV1             = 0x04,
    PacketCodeAckV1                 = 0x05,
    PacketCodeDataV1                = 0x06,
    PacketCodeHardResetClientV2     = 0x07,
    PacketCodeHardResetServerV2     = 0x08,
    PacketCodeDataV2                = 0x09,
    PacketCodeUnknown               = 0xff
};

#define DataPacketNoCompress        0xfa
#define DataPacketNoCompressSwap    0xfb
#define DataPacketLZOCompress       0x66

#define DataPacketV2Indicator       0x50
#define DataPacketV2Uncompressed    0x00

extern const uint8_t DataPacketPingData[16];

@protocol PacketProtocol

@property (nonatomic, readonly) uint32_t packetId;

@end

static inline void PacketOpcodeGet(const uint8_t *from, PacketCode *_Nullable code, uint8_t *_Nullable key)
{
    if (code) {
        *code = (PacketCode)(*from >> 3);
    }
    if (key) {
        *key = *from & 0b111;
    }
}

static inline int PacketHeaderSet(uint8_t *to, PacketCode code, uint8_t key, const uint8_t *_Nullable sessionId)
{
    *(uint8_t *)to = (code << 3) | (key & 0b111);
    int offset = PacketOpcodeLength;
    if (sessionId) {
        memcpy(to + offset, sessionId, PacketSessionIdLength);
        offset += PacketSessionIdLength;
    }
    return offset;
}

static inline int PacketHeaderSetDataV2(uint8_t *to, uint8_t key, uint32_t peerId)
{
    *(uint32_t *)to = ((PacketCodeDataV2 << 3) | (key & 0b111)) | htonl(peerId & 0xffffff);
    return PacketOpcodeLength + PacketPeerIdLength;
}

static inline int PacketHeaderGetDataV2PeerId(const uint8_t *from)
{
    return ntohl(*(const uint32_t *)from & 0xffffff00);
}

#pragma mark - Utils

static inline void PacketSwap(uint8_t *ptr, NSInteger len1, NSInteger len2)
{
    // two buffers due to overlapping
    uint8_t buf1[len1];
    uint8_t buf2[len2];
    memcpy(buf1, ptr, len1);
    memcpy(buf2, ptr + len1, len2);
    memcpy(ptr, buf2, len2);
    memcpy(ptr + len2, buf1, len1);
}

static inline void PacketSwapCopy(uint8_t *dst, NSData *src, NSInteger len1, NSInteger len2)
{
    NSCAssert(src.length >= len1 + len2, @"src is smaller than expected");
    memcpy(dst, src.bytes + len1, len2);
    memcpy(dst + len2, src.bytes, len1);
    const NSInteger preambleLength = len1 + len2;
    memcpy(dst + preambleLength, src.bytes + preambleLength, src.length - preambleLength);
}

NS_ASSUME_NONNULL_END
