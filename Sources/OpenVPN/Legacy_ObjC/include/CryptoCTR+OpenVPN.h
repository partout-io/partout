/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>
#import "CryptoProvider.h"

@import _PartoutCryptoOpenSSL_ObjC;

NS_ASSUME_NONNULL_BEGIN

@interface CryptoCTR (OpenVPN) <DataPathEncrypterProvider, DataPathDecrypterProvider>

@end

NS_ASSUME_NONNULL_END
