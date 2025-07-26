/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

#import "OpenVPNTLSProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// WARNING: not thread-safe
@interface OSSLTLSBox : NSObject <OpenVPNTLSProtocol>

- (nullable NSString *)decryptedKeyFromPath:(NSString *)path passphrase:(NSString *)passphrase error:(NSError * _Nullable __autoreleasing *)error;
- (nullable NSString *)decryptedKeyFromPEM:(NSString *)pem passphrase:(NSString *)passphrase error:(NSError * _Nullable __autoreleasing *)error;

@end

NS_ASSUME_NONNULL_END
