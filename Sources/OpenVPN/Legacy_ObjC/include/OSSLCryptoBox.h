/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

#import "OpenVPNCryptoProtocol.h"

@class ZeroingData;

NS_ASSUME_NONNULL_BEGIN

// WARNING: not thread-safe!
@interface OSSLCryptoBox : NSObject <OpenVPNCryptoProtocol>

- (nullable instancetype)initWithSeed:(ZeroingData *)seed;

@end

NS_ASSUME_NONNULL_END
