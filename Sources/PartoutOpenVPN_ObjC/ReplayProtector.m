// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import "CryptoOpenSSL/Allocation.h"
#import "ReplayProtector.h"

@import _PartoutCryptoOpenSSL_ObjC;

#define HIDDEN_WINSIZE          128
#define BITMAP_LEN              (HIDDEN_WINSIZE / 32)
#define BITMAP_INDEX_MASK       (BITMAP_LEN - 1)
#define REDUNDANT_BIT_SHIFTS    5
#define REDUNDANT_BITS          (1 << REDUNDANT_BIT_SHIFTS)
#define BITMAP_LOC_MASK         (REDUNDANT_BITS - 1)
#define REPLAY_WINSIZE          (HIDDEN_WINSIZE - REDUNDANT_BITS)

@interface ReplayProtector ()

@property (nonatomic, assign) uint32_t highestPacketId;
@property (nonatomic, unsafe_unretained) uint32_t *bitmap;

@end

@implementation ReplayProtector

- (instancetype)init
{
    if ((self = [super init])) {
        self.highestPacketId = 0;
        self.bitmap =  pp_alloc_crypto(BITMAP_LEN * sizeof(uint32_t));
        bzero(self.bitmap, BITMAP_LEN * sizeof(uint32_t));
    }
    return self;
}

- (void)dealloc
{
    free(self.bitmap);
}

- (BOOL)isReplayedPacketId:(uint32_t)packetId
{
    if (packetId == 0) {
        return YES;
    }
    if ((REPLAY_WINSIZE + packetId) < self.highestPacketId) {
        return YES;
    }
    
    uint32_t index = (packetId >> REDUNDANT_BIT_SHIFTS);
    
    if (packetId > self.highestPacketId) {
        const uint32_t currentIndex = self.highestPacketId >> REDUNDANT_BIT_SHIFTS;
        const uint32_t diff = MIN(index - currentIndex, BITMAP_LEN);

        for (uint32_t bid = 0; bid < diff; ++bid) {
            self.bitmap[(bid + currentIndex + 1) & BITMAP_INDEX_MASK] = 0;
        }
        
        self.highestPacketId = packetId;
    }
    
    index &= BITMAP_INDEX_MASK;
    const uint32_t bitLocation = packetId & BITMAP_LOC_MASK;
    const uint32_t bitmask = (1 << bitLocation);
    
    if (self.bitmap[index] & bitmask) {
        return YES;
    }
    self.bitmap[index] |= bitmask;
    return NO;
}

@end
