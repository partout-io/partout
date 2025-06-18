//
//  CryptoCBC.m
//  Partout
//
//  Created by Davide De Rosa on 6/15/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

#import "CryptoBridging.h"
#import "CryptoOpenSSL/CryptoCBC.h"
#import "CryptoOpenSSL/ZeroingData.h"
#import "crypto_openssl/crypto_cbc.h"

@interface CryptoCBC () {
    crypto_cbc_t *ptr;
}
@end

@implementation CryptoCBC

- (nullable instancetype)initWithCipherName:(nullable NSString *)cipherName
                                 digestName:(NSString *)digestName
                                      error:(NSError **)error
{
    NSLog(@"PartoutOpenVPN: Using CryptoCBC (bridged ObjC/C)");
    NSParameterAssert(!cipherName || [[cipherName uppercaseString] hasSuffix:@"CBC"]);
    NSParameterAssert(digestName);

    self = [super init];
    if (self) {
        ptr = crypto_cbc_create([cipherName cStringUsingEncoding:NSUTF8StringEncoding],
                                [digestName cStringUsingEncoding:NSUTF8StringEncoding]);
        if (!ptr) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    crypto_cbc_free(ptr);
}

- (int)cipherIVLength
{
    return (int)ptr->cipher_iv_len;
}

- (int)digestLength
{
    return (int)ptr->crypto.meta.digest_len;
}

- (int)tagLength
{
    return (int)ptr->crypto.meta.tag_len;
}

- (NSInteger)encryptionCapacityWithLength:(NSInteger)length
{
    return ptr->crypto.meta.encryption_capacity(ptr, length);
}

#pragma mark Encrypter

- (void)configureEncryptionWithCipherKey:(ZeroingData *)cipherKey hmacKey:(ZeroingData *)hmacKey
{
    ptr->crypto.encrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr);
}

- (BOOL)encryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    crypto_flags_t cf = crypto_flags_from(flags);
    crypto_error_t code;
    if (!ptr->crypto.encrypter.encrypt(ptr, dest, (size_t *)destLength, bytes, length, &cf, &code)) {
        if (error) {
            *error = [NSError errorWithDomain:PartoutCryptoErrorDomain code:code userInfo:nil];
        }
        return NO;
    }
    return YES;
}

#pragma mark Decrypter

- (void)configureDecryptionWithCipherKey:(ZeroingData *)cipherKey hmacKey:(ZeroingData *)hmacKey
{
    ptr->crypto.decrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr);
}

- (BOOL)decryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    crypto_flags_t cf = crypto_flags_from(flags);
    crypto_error_t code;
    if (!ptr->crypto.decrypter.decrypt(ptr, dest, (size_t *)destLength, bytes, length, &cf, &code)) {
        if (error) {
            *error = [NSError errorWithDomain:PartoutCryptoErrorDomain code:code userInfo:nil];
        }
        return NO;
    }
    return YES;
}

- (BOOL)verifyBytes:(const uint8_t *)bytes length:(NSInteger)length flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    crypto_flags_t cf = crypto_flags_from(flags);
    crypto_error_t code;
    if (!ptr->crypto.decrypter.verify(ptr, bytes, length, &code)) {
        if (error) {
            *error = [NSError errorWithDomain:PartoutCryptoErrorDomain code:code userInfo:nil];
        }
        return NO;
    }
    return YES;
}

@end
