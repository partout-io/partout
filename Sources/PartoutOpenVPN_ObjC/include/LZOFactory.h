/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>
#import "CompressionProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface LZOFactory : NSObject

//+ (NSString *)versionString;
+ (BOOL)canCreate;
+ (nullable id<CompressionProvider>)create;

@end

NS_ASSUME_NONNULL_END
