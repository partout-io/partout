//
//  XOR.h
//  Partout
//
//  Created by Tejas Mehta on 5/24/22.
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

#import "XORMethodNative.h"

static inline
void xor_mask_legacy(uint8_t *dst,
                     const uint8_t *src,
                     size_t srcLength,
                     ZeroingData *xorMask)
{
    assert(xorMask);
    if (!xorMask || xorMask.length == 0) {
        return;
    }
    for (size_t i = 0; i < srcLength; ++i) {
        dst[i] = src[i] ^ ((uint8_t *)(xorMask.bytes))[i % xorMask.length];
    }
}

static inline
void xor_ptrpos_legacy(uint8_t *dst, const uint8_t *src, size_t srcLength)
{
    for (size_t i = 0; i < srcLength; ++i) {
        dst[i] = src[i] ^ (i + 1);
    }
}

static inline
void xor_reverse_legacy(uint8_t *dst, const uint8_t *src, size_t srcLength)
{
    size_t start = 1;
    size_t end = srcLength - 1;
    uint8_t temp = 0;
    dst[0] = src[0];
    while (start < end) {
        temp = src[start];
        dst[start] = src[end];
        dst[end] = temp;
        start++;
        end--;
    }
    if (start == end) {
        dst[start] = src[start];
    }
}

static inline
void xor_obfuscate_legacy(uint8_t *dst, const uint8_t *src, size_t srcLength, ZeroingData *mask, BOOL outbound)
{
    if (outbound) {
        xor_ptrpos_legacy(dst, src, srcLength);
        xor_reverse_legacy(dst, dst, srcLength);
        xor_ptrpos_legacy(dst, dst, srcLength);
        xor_mask_legacy(dst, dst, srcLength, mask);
    } else {
        xor_mask_legacy(dst, src, srcLength, mask);
        xor_ptrpos_legacy(dst, dst, srcLength);
        xor_reverse_legacy(dst, dst, srcLength);
        xor_ptrpos_legacy(dst, dst, srcLength);
    }
}

static inline
void xor_memcpy_legacy(uint8_t *dst, NSData *srcData, XORMethodNative method, ZeroingData *mask, BOOL outbound)
{
    const uint8_t *src = srcData.bytes;
    switch (method) {
        case XORMethodNativeNone:
            memcpy(dst, src, srcData.length);
            break;

        case XORMethodNativeMask:
            xor_mask_legacy(dst, src, srcData.length, mask);
            break;

        case XORMethodNativePtrPos:
            xor_ptrpos_legacy(dst, src, srcData.length);
            break;

        case XORMethodNativeReverse:
            xor_reverse_legacy(dst, src, srcData.length);
            break;

        case XORMethodNativeObfuscate:
            xor_obfuscate_legacy(dst, src, srcData.length, mask, outbound);
            break;
    }
}
