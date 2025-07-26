/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>
#import "CryptoProvider.h"

@import _PartoutCryptoOpenSSL_ObjC;

NS_ASSUME_NONNULL_BEGIN

@interface CryptoAEAD (OpenVPN) <DataPathEncrypterProvider, DataPathDecrypterProvider>

@end

@interface DataPathCryptoAEAD : NSObject <DataPathEncrypter, DataPathDecrypter>

@property (nonatomic, assign) uint32_t peerId;

- (instancetype)initWithCrypto:(CryptoAEAD *)crypto;

@end

NS_ASSUME_NONNULL_END
