// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#import <Foundation/Foundation.h>

#import "CryptoCTR+OpenVPN.h"
#import "DataPathCrypto.h"

@implementation CryptoCTR (OpenVPN)

- (id<DataPathEncrypter>)dataPathEncrypter
{
    [NSException raise:NSInvalidArgumentException format:@"DataPathEncryption not supported"];
    return nil;
}

- (id<DataPathDecrypter>)dataPathDecrypter
{
    [NSException raise:NSInvalidArgumentException format:@"DataPathEncryption not supported"];
    return nil;
}

@end
