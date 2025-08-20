/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const PassepartoutLZOErrorDomain;

@interface StandardLZO : NSObject

- (nullable NSData *)compressedDataWithData:(NSData *)data error:(NSError **)error;
- (nullable NSData *)decompressedDataWithData:(NSData *)data error:(NSError **)error;
- (nullable NSData *)decompressedDataWithBytes:(const uint8_t *)bytes length:(NSInteger)length error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
