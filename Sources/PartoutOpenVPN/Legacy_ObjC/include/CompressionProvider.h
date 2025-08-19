/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Provides tools for (de)compressing data.
@protocol CompressionProvider

/// - Parameters:
///   - data: The data to compress.
///   - error: The error.
/// - Returns: The compressed data.
- (nullable NSData *)compressedDataWithData:(NSData *)data error:(NSError **)error;

/// - Parameters:
///   - data: The data to decompress.
///   - error: The error.
/// - Returns: The decompressed data.
- (nullable NSData *)decompressedDataWithData:(NSData *)data error:(NSError **)error;

/// - Parameters:
///   - data: The data to decompress.
///   - error: The error.
/// - Returns: The decompressed data.
- (nullable NSData *)decompressedDataWithBytes:(const uint8_t *)bytes length:(NSInteger)length error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
