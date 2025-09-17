/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>
#import "CompressionProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface LZOFactory : NSObject

+ (nullable id<CompressionProvider>)create;

@end

NS_ASSUME_NONNULL_END
