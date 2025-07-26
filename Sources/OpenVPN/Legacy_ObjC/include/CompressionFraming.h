/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CompressionFraming) NS_SWIFT_SENDABLE {
    CompressionFramingDisabled,
    CompressionFramingCompLZO,
    CompressionFramingCompress,
    CompressionFramingCompressV2
};
