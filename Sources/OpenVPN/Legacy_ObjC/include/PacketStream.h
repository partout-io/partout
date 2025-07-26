/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

#import "XORMethodNative.h"
#import "CryptoOpenSSL/ZeroingData.h"

NS_ASSUME_NONNULL_BEGIN

@interface PacketStream : NSObject

+ (NSArray<NSData *> *)packetsFromInboundStream:(NSData *)stream
                                          until:(NSInteger *)until
                                      xorMethod:(XORMethodNative)xorMethod
                                        xorMask:(nullable ZeroingData *)xorMask;

+ (NSData *)outboundStreamFromPacket:(NSData *)packet
                           xorMethod:(XORMethodNative)xorMethod
                             xorMask:(nullable ZeroingData *)xorMask;

+ (NSData *)outboundStreamFromPackets:(NSArray<NSData *> *)packets
                            xorMethod:(XORMethodNative)xorMethod
                              xorMask:(nullable ZeroingData *)xorMask;

@end

NS_ASSUME_NONNULL_END
