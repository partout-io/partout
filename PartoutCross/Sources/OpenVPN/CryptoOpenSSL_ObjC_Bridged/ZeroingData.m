//
//  ZeroingData.m
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

#import <Foundation/Foundation.h>
#import "CryptoOpenSSL/ZeroingData.h"
#import "crypto/zeroing_data.h"

@interface ZeroingData () {
    zeroing_data_t *ptr;
}

@end

@implementation ZeroingData

- (instancetype)init
{
    return [self initWithBytes:NULL length:0];
}

- (instancetype)initWithLength:(NSInteger)length
{
    if ((self = [super init])) {
        ptr = zd_create(length);
    }
    return self;
}

- (instancetype)initWithBytes:(const uint8_t *)bytes length:(NSInteger)length
{
    if ((self = [super init])) {
        ptr = zd_create_from_data(bytes, length);
    }
    return self;
}

- (instancetype)initWithUInt8:(uint8_t)uint8
{
    if ((self = [super init])) {
        ptr = zd_create_with_uint8(uint8);
    }
    return self;
}

- (instancetype)initWithUInt16:(uint16_t)uint16
{
    if ((self = [super init])) {
        ptr = zd_create_with_uint16(uint16);
    }
    return self;
}

- (instancetype)initWithData:(NSData *)data
{
    return [self initWithData:data offset:0 length:data.length];
}

- (instancetype)initWithData:(NSData *)data offset:(NSInteger)offset length:(NSInteger)length
{
    NSParameterAssert(data);
    NSParameterAssert(length >= 0);
    NSParameterAssert(offset + length <= data.length);

    if ((self = [super init])) {
        ptr = zd_create_from_data_range(data.bytes, offset, length);
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string nullTerminated:(BOOL)nullTerminated
{
    NSParameterAssert(string);

    if ((self = [super init])) {
        ptr = zd_create_from_string([string cStringUsingEncoding:NSUTF8StringEncoding], nullTerminated);
    }
    return self;
}

- (instancetype)copy
{
    return [[ZeroingData alloc] initWithBytes:ptr->bytes length:ptr->length];
}

- (void)dealloc
{
    zd_free(ptr);
}

- (zeroing_data_t *)ptr
{
    return ptr;
}

- (const uint8_t *)bytes
{
    return zd_bytes(ptr);
}

- (uint8_t *)mutableBytes
{
    return zd_mutable_bytes(ptr);
}

- (NSInteger)length
{
    return zd_length(ptr);
}

- (void)appendData:(ZeroingData *)other
{
    zd_append(ptr, other->ptr);
}

- (void)truncateToSize:(NSInteger)size
{
    NSParameterAssert(size <= ptr->length);

    zd_resize(ptr, size);
}

- (void)removeUntilOffset:(NSInteger)until
{
    NSParameterAssert(until <= ptr->length);

    zd_remove_until(ptr, until);
}

- (void)zero
{
    zd_zero(ptr);
}

- (ZeroingData *)appendingData:(ZeroingData *)other
{
    ZeroingData *copy = [[ZeroingData alloc] init];
    copy->ptr = zd_create_from_data(ptr->bytes, ptr->length);
    zd_append(copy->ptr, other->ptr);
    return copy;
}

- (ZeroingData *)withOffset:(NSInteger)offset length:(NSInteger)length
{
    NSParameterAssert(offset + length <= ptr->length);

    ZeroingData *copy = [[ZeroingData alloc] init];
    copy->ptr = zd_make_slice(ptr, offset, length);
    return copy;
}

- (uint16_t)UInt16ValueFromOffset:(NSInteger)from
{
    NSParameterAssert(from + 2 <= ptr->length);

    return zd_uint16(ptr, from);
}

- (uint16_t)networkUInt16ValueFromOffset:(NSInteger)from
{
    NSParameterAssert(from + 2 <= ptr->length);

    return CFSwapInt16BigToHost(zd_uint16(ptr, from));
}

- (NSString *)nullTerminatedStringFromOffset:(NSInteger)from
{
    NSParameterAssert(from <= ptr->length);

    NSInteger nullOffset = NSNotFound;
    for (NSInteger i = from; i < ptr->length; ++i) {
        if (ptr->bytes[i] == 0) {
            nullOffset = i;
            break;
        }
    }
    if (nullOffset == NSNotFound) {
        return nil;
    }
    const NSInteger stringLength = nullOffset - from;
    return [[NSString alloc] initWithBytes:ptr->bytes length:stringLength encoding:NSUTF8StringEncoding];
}

- (BOOL)isEqual:(id)object
{
    NSParameterAssert(object);

    if (![object isKindOfClass:[ZeroingData class]]) {
        return NO;
    }
    ZeroingData *other = (ZeroingData *)object;
    return zd_equals(ptr, other->ptr);
}

- (BOOL)isEqualToData:(NSData *)data
{
    NSParameterAssert(data);

    if (data.length != ptr->length) {
        return NO;
    }
    return !memcmp(ptr->bytes, data.bytes, ptr->length);
}

- (NSData *)toData
{
    return [NSData dataWithBytes:ptr->bytes length:ptr->length];
}

- (NSString *)toHex
{
    const NSUInteger capacity = ptr->length * 2;
    NSMutableString *hexString = [[NSMutableString alloc] initWithCapacity:capacity];
    for (int i = 0; i < ptr->length; ++i) {
        [hexString appendFormat:@"%02x", ptr->bytes[i]];
    }
    return hexString;
}

@end
