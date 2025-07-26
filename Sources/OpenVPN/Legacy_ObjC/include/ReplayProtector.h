/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

@interface ReplayProtector : NSObject

- (BOOL)isReplayedPacketId:(uint32_t)packetId;

@end
