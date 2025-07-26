/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CompressionAlgorithm) NS_SWIFT_SENDABLE {
    CompressionAlgorithmDisabled,
    CompressionAlgorithmLZO,
    CompressionAlgorithmOther
};
