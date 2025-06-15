//
//  CryptoCTR.m
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
#import "CryptoCTR.h"
#import "ZeroingData.h"
#import "crypto_ctr.h"

@interface CryptoCTR () {
    crypto_ctr_t *ptr;
}
@end

@implementation CryptoCTR

- (nullable instancetype)initWithCipherName:(NSString *)cipherName
                                 digestName:(NSString *)digestName
                                  tagLength:(NSInteger)tagLength
                              payloadLength:(NSInteger)payloadLength
                                      error:(NSError **)error
{
    NSLog(@"PartoutOpenVPN: Using CryptoCTR (bridged ObjC/C)");
    NSParameterAssert(cipherName && [[cipherName uppercaseString] hasSuffix:@"CTR"]);
    NSParameterAssert(digestName);

    self = [super init];
    if (self) {
        ptr = crypto_ctr_create([cipherName cStringUsingEncoding:NSUTF8StringEncoding],
                                [digestName cStringUsingEncoding:NSUTF8StringEncoding],
                                tagLength,
                                payloadLength);
        if (!ptr) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    crypto_ctr_free(ptr);
}

- (int)cipherIVLength
{
    return (int)ptr->cipher_iv_len;
}

- (int)digestLength
{
    return (int)ptr->meta.digest_length;
}

- (int)tagLength
{
    return (int)ptr->meta.tag_length;
}

- (NSInteger)encryptionCapacityWithLength:(NSInteger)length
{
    return ptr->meta.encryption_capacity(ptr, length);
}

#pragma mark Encrypter

- (void)configureEncryptionWithCipherKey:(ZeroingData *)cipherKey hmacKey:(ZeroingData *)hmacKey
{
    ptr->encrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr);
}

- (BOOL)encryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    crypto_flags_t cf = crypto_flags_from(flags);
    crypto_error_t code;
    if (!ptr->encrypter.encrypt(ptr, bytes, length, dest, (size_t *)destLength, &cf, &code)) {
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
    ptr->decrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr);
}

- (BOOL)decryptBytes:(const uint8_t *)bytes length:(NSInteger)length dest:(uint8_t *)dest destLength:(NSInteger *)destLength flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    crypto_flags_t cf = crypto_flags_from(flags);
    crypto_error_t code;
    if (!ptr->decrypter.decrypt(ptr, bytes, length, dest, (size_t *)destLength, &cf, &code)) {
        if (error) {
            *error = [NSError errorWithDomain:PartoutCryptoErrorDomain code:code userInfo:nil];
        }
        return NO;
    }
    return YES;
}

- (BOOL)verifyBytes:(const uint8_t *)bytes length:(NSInteger)length flags:(const CryptoFlags * _Nullable)flags error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    [NSException raise:NSInvalidArgumentException format:@"Verification not supported"];
    return NO;
}

@end
